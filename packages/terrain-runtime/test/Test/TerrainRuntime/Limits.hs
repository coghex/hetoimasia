-- | Every service-wide limit counts every state that still holds the resource, until
-- its release has actually completed. An arena that is closed but whose snapshot is
-- still borrowed holds its resident detail and its place in the model, so it counts
-- against the arena limit until the last borrower returns it; a pending open counts
-- before it settles, a revoked lease until it is released.
module Test.TerrainRuntime.Limits (spec) where

import Control.Concurrent.STM (atomically, check, readTVar)
import Control.Exception (finally)
import Control.Monad (forM_, void)
import Hetoimasia.Terrain.Coordinate (decomposeTile)
import Data.List (isInfixOf, nub)
import Hetoimasia.Terrain.Residency (ArenaPhase (..), Event (..), JobPhase (..), Revision (..), arenaId, arenaPhase, arenaRetainedBytes, jobArena, jobId, jobPhase, jobRegion, modelArenas, modelJobs, modelLimits, modelRegions, newModel, regionHandoff, step)
import Hetoimasia.Terrain.Runtime
import Hetoimasia.Terrain.Runtime.Settlement
import Test.Hspec
import Test.TerrainRuntime.Fixtures
import Test.TerrainRuntime.Usage (jobRunningDisagreements, usageDisagreements)

-- | Every disagreement between the model's ledgers and what the service holds, read in
-- one transaction.
usageOf ∷ Service → IO [String]
usageOf svc = atomically (usageDisagreements <$> inspectCensusSTM svc <*> inspectModelSTM svc)

arenasRow ∷ Service → IO LimitRow
arenasRow svc =
  inspectLimits svc >>= \rows → case filter ((== "arenas") . limitRowName) rows of
    row : _ → pure row
    [] → expectationFailure "no arena limit row" >> fail "no arena limit row"

counted ∷ Service → IO (Word, Word)
counted svc = (\r → (fromIntegral (limitRowCounted r), fromIntegral (limitRowMax r))) <$> arenasRow svc

spec ∷ Spec
spec = describe "Service-wide limits count every state that holds the resource" $ do
  it "keeps a closed arena with a borrowed snapshot counted against the arena limit until the borrower returns it" $
    withService (defaultConfig {configMaxArenas = 2}) $ \svc → do
      (client, first') <- openMain svc "first"
      _ <- okOf (openArena svc client "second" soilOverStone) >>= await svc >>= expectSuccess
      _ <- readCell svc first' (tile 1 1 1)
      let (held, _) = decomposeTile (tile 1 1 1)
      counted svc `shouldReturn` (2, 2)
      outcome <- withSnapshot svc first' [held] $ \_ → do
        -- The creator's lease is released: the arena is closed, but the borrow keeps it.
        void (releaseLease svc first')
        counted svc `shouldReturn` (2, 2)
        inspectInvariants svc >>= (`shouldBe` [])
        -- Four incarnations would exist if this were admitted.
        refusedWith <$> openArena svc client "third" soilOverStone >>= (`shouldBe` Just (RefusedBusy BusyArenas))
        counted svc `shouldReturn` (2, 2)
      either (\r → expectationFailure (show r)) pure outcome
      -- The borrow is returned, the retirement completes, and the place is free.
      waitFor $ inspectModelSTM svc >>= \m → check (length (modelArenas m) == 1)
      counted svc `shouldReturn` (1, 2)
      third <- okOf (openArena svc client "third" soilOverStone) >>= await svc >>= expectSuccess
      _ <- readCell svc third (tile 1 1 1)
      inspectInvariants svc >>= (`shouldBe` [])
      settleChecks svc

  it "with the default limits, four closed incarnations held by snapshots refuse a fifth admission, and releasing exactly one borrow admits a replacement while three stay outstanding" $
    withService defaultConfig $ \svc → do
      (client, first') <- openMain svc "incarnation-1"
      rest <- mapM (\n → okOf (openArena svc client n soilOverStone) >>= await svc >>= expectSuccess) ["incarnation-2", "incarnation-3", "incarnation-4"]
      let leases = first' : rest
          (held, _) = decomposeTile (tile 1 1 1)
      mapM_ (\l → readCell svc l (tile 1 1 1)) leases
      counted svc `shouldReturn` (4, 4)
      -- The fifth open is already refused while all four are live.
      refusedWith <$> openArena svc client "incarnation-5" soilOverStone >>= (`shouldBe` Just (RefusedBusy BusyArenas))
      let retiring = (\m → length [() | a ← modelArenas m, arenaPhase a == ArenaRetiringPhase]) <$> inspectModel svc
          borrow lease = withSnapshot svc lease [held]
          flatten = either (\r → expectationFailure (show r)) pure
      outcome <- case leases of
        [l1, l2, l3, l4] → borrow l1 $ \_ → (>>= flatten) $ borrow l2 $ \_ → (>>= flatten) $ borrow l3 $ \_ → do
          inner <- borrow l4 $ \_ → do
            -- Every incarnation is closed, and each is kept by its snapshot.
            mapM_ (releaseLease svc) leases
            retiring `shouldReturn` 4
            counted svc `shouldReturn` (4, 4)
            refusedWith <$> openArena svc client "incarnation-5" soilOverStone >>= (`shouldBe` Just (RefusedBusy BusyArenas))
            inspectInvariants svc >>= (`shouldBe` [])
          flatten inner
          -- Exactly one borrow was returned; three are outstanding.
          waitFor $ inspectModelSTM svc >>= \m → check (length (modelArenas m) == 3)
          retiring `shouldReturn` 3
          counted svc `shouldReturn` (3, 4)
          replacement <- okOf (openArena svc client "incarnation-5" soilOverStone) >>= await svc >>= expectSuccess
          counted svc `shouldReturn` (4, 4)
          -- The replacement took the only free place: another is refused again.
          refusedWith <$> openArena svc client "incarnation-6" soilOverStone >>= (`shouldBe` Just (RefusedBusy BusyArenas))
          inspectInvariants svc >>= (`shouldBe` [])
          void (releaseLease svc replacement)
        _ → expectationFailure "four leases expected" >> fail "four leases expected"
      flatten outcome
      waitFor $ inspectModelSTM svc >>= \m → check (null (modelArenas m))
      counted svc `shouldReturn` (0, 4)
      settleChecks svc

  it "counts a pending open before it settles" $
    withService (defaultConfig {configMaxArenas = 1}) $ \svc → do
      client <- okOf (registerClient svc)
      host <- newHost False
      _ <- okOf (openArenaWith svc (hostEndpoint svc Nothing host) client "first" soilOverStone)
      counted svc `shouldReturn` (1, 1)
      refusedWith <$> openArena svc client "second" soilOverStone >>= (`shouldBe` Just (RefusedBusy BusyArenas))
      inspectInvariants svc >>= (`shouldBe` [])
      grant host
      waitFor $ inspectModelSTM svc >>= \m → check (length (modelArenas m) == 1)
      counted svc `shouldReturn` (1, 1)

  it "releases a cancelled open's place at once: it counts as no arena, no lease and no command slot" $
    withService defaultConfig $ \svc → do
      (client, _) <- openMain svc "main"
      host <- newHost False
      request <- okOf (openArenaWith svc (hostEndpoint svc Nothing host) client "second" soilOverStone)
      void (cancel svc request)
      waitFor (readTVar (hostSettled host) >>= check . not . null)
      rows <- inspectLimits svc
      [limitRowCounted r | r ← rows, limitRowName r == "arenas"] `shouldBe` [1]
      [limitRowCounted r | r ← rows, limitRowName r == "leases"] `shouldBe` [1]
      [limitRowCounted r | r ← rows, limitRowName r == "command slots"] `shouldBe` [0]
      inspectInvariants svc >>= (`shouldBe` [])
      retire svc request
      settleChecks svc

  it "derives every bank from the entities while a transfer holds its duplicate, a removal holds its reservation and a snapshot is borrowed" $ do
    gate <- newDisarmedGate
    withGatedService defaultConfig alwaysAdmitting (\p → case p of PointHandoff {} → True; _ → False) gate $ \svc → (\act → act `finally` openGate gate) $ do
      (_, lease) <- openMain svc "main"
      _ <- readCell svc lease (tile 1 1 1)
      let (held, _) = decomposeTile (tile 1 1 1)
      armGate gate
      outcome <- withSnapshot svc lease [held] $ \_ → do
        _ <- removeCell' svc lease (tile 1 1 1)
        -- The owner is in the middle of the region's transfer: its duplicate is charged
        -- to staging, beside the borrow's hold and the arena's retained edit.
        awaitReached gate
        model <- inspectModel svc
        [d | Just d ← map regionHandoff (modelRegions model)] `shouldSatisfy` (not . null)
        usageOf svc `shouldReturn` []
        inspectInvariants svc >>= (`shouldBe` [])
        openGate gate
        waitFor $ inspectModelSTM svc >>= \m → check (all ((== Nothing) . regionHandoff) (modelRegions m))
        usageOf svc `shouldReturn` []
      either (\r → expectationFailure (show r)) pure outcome
      settleChecks svc

  -- The usage check must notice a model that has lost a record while the service still
  -- holds the resource: the model here is rebuilt without the arena (an empty arena of
  -- the same identity, no regions, no requests, no holds) beside the service's real
  -- census. Every bank and slot must disagree.
  it "notices a model that dropped its records while the service still holds the resources, in every bank" $ do
    gate <- newDisarmedGate
    withGatedService defaultConfig alwaysAdmitting (\p → case p of PointStaging _ → True; _ → False) gate $ \svc → (\act → act `finally` openGate gate) $ do
      (_, lease) <- openMain svc "main"
      _ <- readCell svc lease (tile 1 1 1)
      -- A committed edit: retained changes and resident detail the service holds.
      _ <- removeCell' svc lease (tile 1 1 1)
      let (held, _) = decomposeTile (tile 1 1 1)
      armGate gate
      host <- newHost True
      _ <- okOf (removeWith svc (hostEndpoint svc Nothing host) lease (tile 1 1 2) Nothing)
      awaitReached gate
      outcome <- withSnapshot svc lease [held] $ \_ → do
        (model, census) <- atomically ((,) <$> inspectModelSTM svc <*> inspectCensusSTM svc)
        -- The honest model agrees with the service ...
        usageDisagreements census model `shouldBe` []
        -- ... and one that lost its arena's records does not, bank by bank.
        let broken = case [arenaId info | info ← modelArenas model] of
              aid : _ → fst (step (newModel (modelLimits model)) (OpenArena aid (Revision 0)))
              [] → newModel (modelLimits model)
            found = usageDisagreements census broken
            mentions needle = any (needle `isInfixOf`) found
        mentions "resident bytes of region" || mentions "no record of it" `shouldBe` True
        mentions "edit bank occupied" `shouldBe` True
        mentions "edit bank reserved" `shouldBe` True
        mentions "staging bank occupied" `shouldBe` True
        mentions "command slots" `shouldBe` True
        mentions "snapshot holds" `shouldBe` True
      either (\r → expectationFailure (show r)) pure outcome
      openGate gate
      void (settledOf host)

  -- The accounting rule is that nothing is under-charged, not that the charge is exact: the
  -- model keeps a monotone, conservative retained charge when edits coalesce.
  it "charges coalescing edits at least what the arena holds (remove levels 0, 2, then 1)" $
    withService defaultConfig $ \svc → do
      (_, lease) <- openMain svc "main"
      _ <- readCell svc lease (tile 1 1 0)
      forM_ [tile 1 1 0, tile 1 1 2, tile 1 1 1] $ \at → do
        _ <- removeCell' svc lease at
        usageOf svc `shouldReturn` []
      (model, census) <- atomically ((,) <$> inspectModelSTM svc <*> inspectCensusSTM svc)
      let charged = [arenaRetainedBytes info | info ← modelArenas model]
          held = map censusRetainedBytes (censusArenas census)
      length charged `shouldBe` 1
      -- Never under-charged; the coalesced interval may be charged more than it now holds.
      zipWith (>=) charged held `shouldBe` [True]
      -- (and here it is in fact charged more: exact equality would fail this sequence)
      zipWith (>) charged held `shouldBe` [True]
      inspectInvariants svc >>= (`shouldBe` [])
      settleChecks svc

  -- A job the owner is about to run must still be charged: a model that already forgot it
  -- (an early acknowledgement) is under-charging it.
  it "notices a model that forgot a load job the owner is about to run" $ do
    gate <- newDisarmedGate
    withGatedService defaultConfig alwaysAdmitting (\p → case p of PointJob {} → True; _ → False) gate $ \svc → (\act → act `finally` openGate gate) $ do
      client <- okOf (registerClient svc)
      lease <- okOf (openArena svc client "main" soilOverStone) >>= await svc >>= expectSuccess
      armGate gate
      host <- newHost True
      _ <- okOf (cellWith svc (hostEndpoint svc Nothing host) lease (tile 1 1 1))
      awaitReached gate
      model <- inspectModel svc
      case [(jobId j, jobArena j, jobRegion j) | j ← modelJobs model, jobPhase j == JobRunningPhase] of
        (jid, arena, loaded) : _ → do
          jobRunningDisagreements model arena loaded `shouldBe` []
          let forgotten = fst (step model (JobFailed jid))
          jobRunningDisagreements forgotten arena loaded `shouldSatisfy` (not . null)
        [] → expectationFailure "the owner is at a job but the model holds none running"
      openGate gate
      void (settledOf host)

  -- One arena's retained charge swapped with another's: neither total nor count changes,
  -- but each arena must be charged at least what it holds.
  it "notices retained charges swapped between two arenas" $
    withService defaultConfig $ \svc → do
      (client, first') <- openMain svc "first"
      second <- okOf (openArena svc client "second" soilOverStone) >>= await svc >>= expectSuccess
      _ <- readCell svc first' (tile 1 1 0)
      _ <- readCell svc second (tile 1 1 0)
      -- One edit in the first arena, two (in separate columns) in the second.
      _ <- removeCell' svc first' (tile 1 1 0)
      forM_ [tile 1 1 0, tile 3 3 0] $ \at → readCell svc second at >> removeCell' svc second at
      (model, census) <- atomically ((,) <$> inspectModelSTM svc <*> inspectCensusSTM svc)
      usageDisagreements census model `shouldBe` []
      let held = map censusRetainedBytes (censusArenas census)
      length (nub held) `shouldBe` 2
      -- The same census with the two arenas' retained bytes exchanged.
      let swapped = census {censusArenas = zipWith (\a v → a {censusRetainedBytes = v}) (censusArenas census) (reverse held)}
      usageDisagreements swapped model `shouldSatisfy` any ("retained bytes of arena" `isInfixOf`)
