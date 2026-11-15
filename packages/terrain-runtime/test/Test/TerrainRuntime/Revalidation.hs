-- | Superseded work, stale preconditions and deterministic ordering.
module Test.TerrainRuntime.Revalidation (spec) where

import Control.Concurrent.STM
import Control.Concurrent (yield)
import Control.Monad (forM, forM_)
import Hetoimasia.Terrain.Residency (ArenaId (..), Revision (..), modelRegions, regionCoord)
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
