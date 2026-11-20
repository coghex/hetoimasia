-- | Superseded work, stale preconditions and deterministic ordering.
module Test.TerrainRuntime.Revalidation (spec) where

import Control.Concurrent.STM
import Control.Concurrent (yield)
import Control.Monad (forM, forM_)
import Data.Word (Word64)
import Hetoimasia.Terrain.Coordinate (RegionCoord (..), decomposeTile)
import Hetoimasia.Terrain.Residency (ArenaId (..), Bank (StagingBank), JobPhase (..), Ledger (..), RegionDemand (..), Revision (..), bankLedger, coverageBox, coverageTile, jobPhase, modelJobs, modelRegions, modelViews, regionCoord, viewPending)
import Hetoimasia.Terrain.Runtime
import Hetoimasia.Terrain.Runtime.Settlement
import Test.Hspec
import Test.Support.Bounded (bounded)
import Test.TerrainRuntime.Fixtures

-- | One step of an ordered trace.
data Op = Remove (Integer, Integer, Integer) | Read (Integer, Integer, Integer)
  deriving stock (Show)

-- | What one step answered: the kind, the revision it carried and the result.
data Seen = SawRemoval Bool Revision | SawCell Revision (Maybe (String, Int))
  deriving stock (Eq, Show)

-- | A trace across several regions and columns, with reads between edits and a
-- repeat that is a no-op. Cells stay inside a 2 x 1 x 2 extent.
trace ∷ [Op]
trace =
  [ Read (0, 0, 0), Remove (0, 0, 0), Read (0, 0, 0), Remove (16, 0, 1), Read (16, 0, 1)
  , Remove (0, 0, 0), Remove (1, 0, 32), Read (1, 0, 32), Read (0, 0, 33), Remove (0, 0, 33)
  , Remove (-16, 0, -32), Read (-16, 0, -32), Read (0, 0, 1), Remove (0, 16, 0), Read (0, 16, 0)
  , Remove (17, 0, 33), Read (16, 0, 33), Remove (1, 0, 0), Read (1, 0, 0), Read (0, 0, 32)
  , Read (32, 0, 0), Read (-32, 0, 0), Read (0, -16, 0), Read (0, 32, 0), Read (48, 0, 0)
  , Read (-48, 0, 0), Remove (0, 0, -32), Read (0, 0, -32), Read (0, 0, -64), Read (0, 0, 0)
  , Read (0, 0, 33), Read (-16, 0, -32), Remove (32, 0, 1), Read (32, 0, 1), Read (16, 0, 1)
  ]

runTrace ∷ Service → ArenaLease → IO [Seen]
runTrace svc lease = concat <$> mapM batch (chunks 5 trace)
  where
    chunks _ [] = []
    chunks n xs = take n xs : chunks n (drop n xs)
    -- Busy is transient pressure (a region whose detail is being released, a
    -- full queue): the command is admitted again, in the same place in the trace.
    admitted submit = bounded $ do
      r <- submit
      case r of
        Left (RefusedBusy _) → yield >> admitted submit
        other → expectRight other
    -- A whole batch is admitted before any is awaited, so the commands queue in
    -- one fixed order while their loads and evictions interleave freely.
    batch ops = do
      pendings <- forM ops $ \op → case op of
        Remove (x, y, z) → Left <$> admitted (removeAt svc lease (tile x y z) Nothing)
        Read (x, y, z) → Right <$> admitted (cellAt svc lease (tile x y z))
      forM pendings $ \p → case p of
        Left removal → (\a → SawRemoval (removeChangedFlag a) (removeRevision a)) <$> (await svc removal >>= expectSuccess)
        Right reading → (\a → SawCell (cellRevision a) (cellMaterial (cellValue a))) <$> (await svc reading >>= expectSuccess)

spec ∷ Spec
spec = describe "Superseded work and ordering" $ do
  it "recomputes a staged read that a committed edit superseded, and never relabels it" $
    withService defaultConfig $ \svc → do
      (_, lease) <- openMain svc "main"
      host <- newHost False
      -- The read is staged against revision 0 and held there.
      _ <- okOf (cellWith svc (hostEndpoint svc Nothing host) lease (tile 3 4 5))
      waitFor (readTVar (hostReady host) >>= \n → check (n >= 1))
      -- An edit commits meanwhile.
      removed <- removeCell' svc lease (tile 3 4 5)
      removeRevision removed `shouldBe` Revision 1
      -- Granted, the read is offered again against the revision it now sees.
      grant host
      settled <- waitFor (readTVar (hostSettled host) >>= \s → if null s then retry else pure s)
      case settled of
        [Succeeded (ACell answer)] → (cellRevision answer, cellIs answer) `shouldBe` (Revision 1, True)
        other → expectationFailure ("unexpected settlement " <> show other)
      settleChecks svc

  it "answers stale_view for a stale content precondition and changes nothing" $
    withService defaultConfig $ \svc → do
      (_, lease) <- openMain svc "main"
      first' <- removeCell' svc lease (tile 3 4 5)
      let current = Precondition (removeIncarnation first') (removeRevision first')
          old = Precondition (removeIncarnation first') (Revision 0)
          foreignIncarnation = Precondition (ArenaId 99) (removeRevision first')
      -- A precondition naming an older revision is stale, even for a cell already air.
      okOf (removeAt svc lease (tile 3 4 5) (Just old)) >>= await svc >>= (`shouldBe` Left (Failed StaleView))
      -- So is another incarnation.
      okOf (removeAt svc lease (tile 1 1 1) (Just foreignIncarnation)) >>= await svc >>= (`shouldBe` Left (Failed StaleView))
      unchanged <- readCell svc lease (tile 1 1 1)
      (cellRevision unchanged, cellIs unchanged) `shouldBe` (Revision 1, False)
      -- The current precondition removes.
      removed <- okOf (removeAt svc lease (tile 1 1 1) (Just current)) >>= await svc >>= expectSuccess
      removed `shouldBe` RemoveAnswer (removeIncarnation first') (Revision 2) True
      settleChecks svc

  it "answers stale_view for a stale knowledge revision in a view precondition, and removes under the current one" $
    withService defaultConfig $ \svc → do
      (_, lease) <- openMain svc "main"
      first' <- removeCell' svc lease (tile 3 4 5)
      status <- okOf (arenaStatus svc lease)
      let knowledge = statusKnowledgeRevision status
          withKnowledge k = PreconditionWith (removeIncarnation first') (removeRevision first') (Just k) Nothing
      okOf (removeAt svc lease (tile 1 1 1) (Just (withKnowledge (Revision 999)))) >>= await svc >>= (`shouldBe` Left (Failed StaleView))
      (cellIs <$> readCell svc lease (tile 1 1 1)) `shouldReturn` False
      removed <- okOf (removeAt svc lease (tile 1 1 1) (Just (withKnowledge knowledge))) >>= await svc >>= expectSuccess
      removeChangedFlag removed `shouldBe` True
      settleChecks svc

  it "reads a precondition's guard in the arbitration: one that does not hold, or retries, answers stale_view and changes nothing" $
    withService defaultConfig $ \svc → do
      (_, lease) <- openMain svc "main"
      first' <- removeCell' svc lease (tile 3 4 5)
      let guarded identity holds = Just (PreconditionWith (removeIncarnation first') (removeRevision first') Nothing (Just (PreconditionGuard identity Nothing holds)))
      okOf (removeAt svc lease (tile 1 1 1) (guarded 1 (pure False))) >>= await svc >>= (`shouldBe` Left (Failed StaleView))
      okOf (removeAt svc lease (tile 1 1 1) (guarded 2 retry)) >>= await svc >>= (`shouldBe` Left (Failed StaleView))
      -- A guard over air is read as well: the no-op removal of a cell already air is stale too.
      okOf (removeAt svc lease (tile 3 4 5) (guarded 3 (pure False))) >>= await svc >>= (`shouldBe` Left (Failed StaleView))
      (cellIs <$> readCell svc lease (tile 1 1 1)) `shouldReturn` False
      removed <- okOf (removeAt svc lease (tile 1 1 1) (guarded 4 (pure True))) >>= await svc >>= expectSuccess
      removeChangedFlag removed `shouldBe` True
      settleChecks svc

  it "refuses a guard bound to another service, though both services name the same arena and revisions, and takes one bound to itself" $
    withService defaultConfig $ \issuer → withService defaultConfig $ \recipient → do
      (_, issued) <- openMain issuer "main"
      (_, lease) <- openMain recipient "main"
      first' <- removeCell' issuer issued (tile 3 4 5)
      second' <- removeCell' recipient lease (tile 3 4 5)
      -- the two services' arena and revisions are equal numbers
      (removeIncarnation first', removeRevision first') `shouldBe` (removeIncarnation second', removeRevision second')
      let boundTo svc = Just (PreconditionWith (removeIncarnation second') (removeRevision second') Nothing (Just (PreconditionGuard 1 (Just (serviceIdentity svc)) (pure True))))
      okOf (removeAt recipient lease (tile 1 1 1) (boundTo issuer)) >>= await recipient >>= (`shouldBe` Left (Failed StaleView))
      (cellIs <$> readCell recipient lease (tile 1 1 1)) `shouldReturn` False
      removed <- okOf (removeAt recipient lease (tile 1 1 1) (boundTo recipient)) >>= await recipient >>= expectSuccess
      removeChangedFlag removed `shouldBe` True
      settleChecks recipient
      settleChecks issuer

  it "refuses a removal whose guard held at admission and staging but not at the arbitration, and commits nothing" $
    withService defaultConfig $ \svc → do
      (_, lease) <- openMain svc "main"
      holds <- newTVarIO True
      host <- newHost False
      let precondition = Just (PreconditionWith (ArenaId 0) (Revision 0) Nothing (Just (PreconditionGuard 7 Nothing (readTVar holds))))
      _ <- okOf (removeWith svc (hostEndpoint svc Nothing host) lease (tile 1 1 1) precondition)
      -- Staged and waiting for its host's eligibility, with the guard still holding.
      waitFor (readTVar (hostReady host) >>= \n → check (n >= 1))
      atomically (writeTVar holds False)
      grant host
      settled <- waitFor (readTVar (hostSettled host) >>= \s → if null s then retry else pure s)
      settled `shouldBe` [Failed StaleView]
      (cellIs <$> readCell svc lease (tile 1 1 1)) `shouldReturn` False
      settleChecks svc

  it "charges an outside staging account what the model's staging holds, and returns all of it after the drain" $ do
    held <- newTVarIO (0 ∷ Word64)
    inside <- withService defaultConfig {configStagingAccount = Just (accountOver held maxBound)} $ \svc → do
      (_, lease) <- openMain svc "main"
      _ <- removeCell' svc lease (tile 1 1 1)
      charged <- readTVarIO held
      model <- atomically (stagingUse <$> inspectModelSTM svc)
      pure (charged, model)
    -- the account holds exactly what the model's staging holds beside the snapshot backing bank's carve-out, and
    -- nothing is left once the service has drained
    fst inside `shouldBe` snd inside + configRetainedBytes defaultConfig
    readTVarIO held `shouldReturn` 0
    -- an account that cannot hold the carve-out refuses the service, with nothing started and nothing reserved
    small <- newTVarIO (0 ∷ Word64)
    withService defaultConfig {configStagingAccount = Just (accountOver small (configRetainedBytes defaultConfig - 1))} (\_ → pure ())
      `shouldThrow` \case ConfigStagingAccount _ _ → True; _ → False
    readTVarIO small `shouldReturn` 0

  it "funds a regional snapshot's reservation only from the account's carve-out, never outside it" $ do
    held <- newTVarIO (0 ∷ Word64)
    withService defaultConfig {configStagingAccount = Just (accountOver held maxBound)} $ \svc → do
      (_, lease) <- openMain svc "main"
      let besideModel = do
            charged ← readTVar held
            model ← inspectModelSTM svc
            pure (charged - stagingUse model)
      atomically besideModel `shouldReturn` configRetainedBytes defaultConfig
      borrow ← okOf (requestRegionSnapshot svc lease [RegionCoord 0 0 0]) >>= await svc >>= either (fail . show) pure
      -- the copy's reservation and footprint live in the backing bank, which the carve-out already holds
      atomically besideModel `shouldReturn` configRetainedBytes defaultConfig
      releaseRegionBorrow svc borrow
      atomically besideModel `shouldReturn` configRetainedBytes defaultConfig

  it "refuses camera demand whole while the shared account, not the model, is the binding limit, and admits it once another consumer releases" $ do
    held <- newTVarIO (0 ∷ Word64)
    withService defaultConfig {configStagingAccount = Just (accountOver held (64 * 1024 * 1024))} $ \svc → do
      (client, lease) <- openMain svc "main"
      view <- okOf (openView svc client)
      demands <- either (fail . show) pure (traverse (\r → RegionDemand r <$> coverageBox 0 16 0 16 0 32) [RegionCoord 0 0 0, RegionCoord 1 0 0, RegionCoord 0 1 0])
      -- another consumer takes all but one byte of what is left
      other <- atomically $ do
        now <- readTVar held
        let taken = 64 * 1024 * 1024 - now - 1
        writeTVar held (now + taken)
        pure taken
      let fillAgain = atomically $ do
            now <- readTVar held
            let room = 64 * 1024 * 1024 - now
            writeTVar held (now + room)
            pure room
      used0 <- atomically (stagingUse <$> inspectModelSTM svc)
      setViewDemand svc view lease demands >>= \case
        Left (RefusedBusy _) → pure ()
        other' → expectationFailure ("expected busy, found " <> show other')
      -- nothing was admitted: no partial camera admission, the model's staging unchanged
      atomically (stagingUse <$> inspectModelSTM svc) `shouldReturn` used0
      -- the other consumer releases; the view sends its latest demand again and it is admitted
      atomically (modifyTVar' held (subtract other))
      _ <- okOf (setViewDemand svc view lease demands)
      used1 <- atomically (stagingUse <$> inspectModelSTM svc)
      used1 `shouldSatisfy` (> used0)
      readTVarIO held `shouldReturn` (used1 + configRetainedBytes defaultConfig)
      -- releasing steps are never refused by the account: with the account full again, the view's demand clears and
      -- the view closes, and their staging returns
      _ <- fillAgain
      _ <- okOf (clearViewDemand svc view)
      closeView svc view
      atomically (stagingUse <$> inspectModelSTM svc) >>= (`shouldSatisfy` (< used1))
      settleChecks svc

  it "retries pending camera demand when another consumer releases the shared account, with no other event" $ do
    held <- newTVarIO (0 ∷ Word64)
    refusals <- newTVarIO (0 ∷ Int)
    let limit = 64 * 1024 * 1024
        counted =
          (accountOver held limit)
            { stagingAccountReserve = \wanted → readTVar held >>= \now →
                if wanted > limit - now then False <$ modifyTVar' refusals (+ 1) else True <$ writeTVar held (now + wanted)
            }
    withService (tightConfig (2, 1, 2) 0 4096) {configStagingAccount = Just counted} $ \svc → do
      (client, lease) <- openMain svc "main"
      view <- okOf (openView svc client)
      let oneCellOf (x, z) = let (area, local) = decomposeTile (tile x 0 z) in RegionDemand area (coverageTile local)
          heldCells = [(0, 0), (16, 0)]
          wanted = [oneCellOf (x, z) | x ← [32, 48, 64, -16, -32, -48, 80, 96], z ← [0, 32]]
          pendingNow = concatMap viewPending . modelViews <$> inspectModelSTM svc
      forM_ heldCells $ \(x, z) → readCell svc lease (tile x 0 z)
      let heldRegions = [fst (decomposeTile (tile x 0 z)) | (x, z) ← heldCells]
      (other, refusedBefore) <- withSnapshot svc lease heldRegions (\_ → do
        _ <- okOf (setViewDemand svc view lease wanted)
        bounded (atomically (inspectModelSTM svc >>= \m → check (null [() | j ← modelJobs m, jobPhase j /= JobQueued && jobPhase j /= JobWaiting])))
        atomically pendingNow >>= (`shouldSatisfy` (not . null))
        -- another consumer takes all the account's room before the borrow ends
        atomically $ do
          now <- readTVar held
          writeTVar held limit
          (,) (limit - now) <$> readTVar refusals)
        >>= either (fail . show) pure
      -- the borrow's end makes the owner retry; the account refuses the pending regions' admission
      bounded (atomically (readTVar refusals >>= check . (> refusedBefore)))
      atomically pendingNow >>= (`shouldSatisfy` (not . null))
      -- the other consumer releases; nothing else happens, and the owner admits what was pending
      atomically (modifyTVar' held (subtract other))
      bounded (atomically (pendingNow >>= check . null))
      inspectDefects svc >>= (`shouldBe` [])

  it "counts every capacity return in the freed cell, two returns in a row with no retry between them included" $
    withService defaultConfig $ \svc → do
      (_, lease) <- openMain svc "main"
      -- two regional borrows, then nothing pending that the owner could retry
      first' <- okOf (requestRegionSnapshot svc lease [RegionCoord 0 0 0]) >>= await svc >>= either (fail . show) pure
      second <- okOf (requestRegionSnapshot svc lease [RegionCoord 1 0 0]) >>= await svc >>= either (fail . show) pure
      before <- atomically (capacityFreedSTM svc)
      -- each return moves the cell, the second though the first already left the owner something to retry
      releaseRegionBorrow svc first'
      once <- atomically (capacityFreedSTM svc)
      once `shouldSatisfy` (> before)
      releaseRegionBorrow svc second
      atomically (capacityFreedSTM svc) >>= (`shouldSatisfy` (> once))
      inspectDefects svc >>= (`shouldBe` [])

  it "re-prepares an edit that another edit overtook and commits both in admission order" $
    withService defaultConfig $ \svc → do
      (_, lease) <- openMain svc "main"
      hostA <- newHost False
      hostB <- newHost False
      -- Both are admitted at revision 0 and staged; B is eligible first.
      _ <- okOf (removeWith svc (hostEndpoint svc Nothing hostA) lease (tile 1 1 1) Nothing)
      _ <- okOf (removeWith svc (hostEndpoint svc Nothing hostB) lease (tile 2 2 2) Nothing)
      waitFor (readTVar (hostReady hostA) >>= \n → check (n >= 1))
      waitFor (readTVar (hostReady hostB) >>= \n → check (n >= 1))
      grant hostB
      _ <- waitFor (readTVar (hostSettled hostB) >>= \s → if null s then retry else pure s)
      grant hostA
      _ <- waitFor (readTVar (hostSettled hostA) >>= \s → if null s then retry else pure s)
      settledOf hostB `shouldReturn` [Succeeded (ARemoved (RemoveAnswer (ArenaId 0) (Revision 1) True))]
      -- A was staged at revision 0 and offered again at 1: it commits as revision 2.
      settledOf hostA `shouldReturn` [Succeeded (ARemoved (RemoveAnswer (ArenaId 0) (Revision 2) True))]
      for2 <- mapM (\(x, y, z) → readCell svc lease (tile x y z)) [(1, 1, 1), (2, 2, 2)]
      map cellIs for2 `shouldBe` [True, True]
      settleChecks svc

  it "commits the same ordered trace to the same results and terrain under different residency schedules" $ do
    let settle cfg = withService cfg $ \svc → do
          client <- okOf (registerClient svc)
          lease <- okOf (openArena svc client "main" soilOverStone) >>= await svc >>= expectSuccess
          seen <- runTrace svc lease
          view <- inspectArena svc lease >>= maybe (fail "arena vanished") pure
          model <- inspectModel svc
          settleChecks svc
          pure (seen, viewKnowledgeRevision view, viewRevision view, map regionCoord (modelRegionsOf model))
    (roomySeen, roomyChanges, roomyRevision, roomyList) <- settle (tightConfig' 400)
    (tightSeen, tightChanges, tightRevision, tightList) <- settle (tightConfig' 0)
    tightSeen `shouldBe` roomySeen
    tightChanges `shouldBe` roomyChanges
    tightRevision `shouldBe` roomyRevision
    -- The schedules really differed: the tight run held far fewer regions.
    (length tightList, length roomyList) `shouldSatisfy` uncurry (<)
    forM_ (zip trace roomySeen) $ \(op, found) → case (op, found) of
      (Read at, SawCell _ material) → material `shouldSatisfy` const (at == at)
      _ → pure ()
  where
    tightConfig' spare = tightConfig (2, 1, 2) spare 4096
    modelRegionsOf = modelRegions
    -- An outside account over a variable, of this size.
    accountOver held limit =
      StagingAccount
        { stagingAccountLimit = limit
        , stagingAccountReserve = \wanted → readTVar held >>= \now → if wanted > limit - now then pure False else True <$ writeTVar held (now + wanted)
        , stagingAccountRelease = \returned → modifyTVar' held (subtract returned)
        , stagingAccountCharged = readTVar held
        }
    stagingUse model = let l = bankLedger model StagingBank in ledgerOccupied l + ledgerReserved l
