-- | Every service-wide limit counts every state that still holds the resource, until
-- its release has actually completed. An arena that is closed but whose snapshot is
-- still borrowed holds its resident detail and its place in the model, so it counts
-- against the arena limit until the last borrower returns it; a pending open counts
-- before it settles, a revoked lease until it is released.
module Test.TerrainRuntime.Limits (spec) where

import Control.Concurrent.STM (check, readTVar)
import Control.Monad (void)
import Hetoimasia.Terrain.Coordinate (decomposeTile)
import Hetoimasia.Terrain.Residency (ArenaPhase (..), arenaPhase, modelArenas)
import Hetoimasia.Terrain.Runtime
import Hetoimasia.Terrain.Runtime.Settlement
import Test.Hspec
import Test.TerrainRuntime.Fixtures

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
