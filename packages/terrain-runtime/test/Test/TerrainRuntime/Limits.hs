-- | Every service-wide limit counts every state that still holds the resource, until
-- its release has actually completed. An arena that is closed but whose snapshot is
-- still borrowed holds its resident detail and its place in the model, so it counts
-- against the arena limit until the last borrower returns it; a pending open counts
-- before it settles, a revoked lease until it is released.
module Test.TerrainRuntime.Limits (spec) where

import Control.Concurrent.STM (check)
import Control.Monad (void)
import Hetoimasia.Terrain.Coordinate (decomposeTile)
import Hetoimasia.Terrain.Residency (modelArenas)
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

  it "admits again as soon as one of two outstanding borrowers returns, and not before" $
    withService (defaultConfig {configMaxArenas = 2}) $ \svc → do
      (client, first') <- openMain svc "first"
      second <- okOf (openArena svc client "second" soilOverStone) >>= await svc >>= expectSuccess
      _ <- readCell svc first' (tile 1 1 1)
      _ <- readCell svc second (tile 1 1 1)
      let (held, _) = decomposeTile (tile 1 1 1)
      outcome <- withSnapshot svc first' [held] $ \_ → withSnapshot svc second [held] $ \_ → do
        void (releaseLease svc first')
        void (releaseLease svc second)
        counted svc `shouldReturn` (2, 2)
        refusedWith <$> openArena svc client "third" soilOverStone >>= (`shouldBe` Just (RefusedBusy BusyArenas))
        inspectInvariants svc >>= (`shouldBe` [])
      either (\r → expectationFailure (show r)) (either (\r → expectationFailure (show r)) pure) outcome
      waitFor $ inspectModelSTM svc >>= \m → check (null (modelArenas m))
      counted svc `shouldReturn` (0, 2)
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
