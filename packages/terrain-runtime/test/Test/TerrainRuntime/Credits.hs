-- | The two rules that govern every credit and every refusal in the service.
--
-- R1: credits are released only at the owner's safe point, after any in-flight
-- work that holds them has finished. A cancellation, a lease release or a closure
-- that arrives while the owner is preparing a request ends the request at once but
-- gives nothing back until the preparation has ended.
--
-- R2: a refusal for want of capacity is never terminal. The item stays pending and
-- is reconsidered whenever capacity is returned.
module Test.TerrainRuntime.Credits (spec) where

import Control.Concurrent.STM
import Control.Monad (forM, forM_, void)
import Hetoimasia.Terrain.Residency
import Hetoimasia.Terrain.Runtime
import Hetoimasia.Terrain.Runtime.Settlement
import Hetoimasia.Terrain.Source (SourceSpec)
import Test.Hspec
import Test.TerrainRuntime.Fixtures

-- | What the model has reserved: its three banks and the command slots.
reserved ∷ Service → IO ([Word], Word)
reserved svc = do
  model <- inspectModel svc
  pure ([fromIntegral (ledgerReserved (bankLedger model b)) | b ← [ResidentBank, EditBank, StagingBank]], fromIntegral (slotInUse model CommandSlot))

data Release = Cancel | ReleaseLease | CloseService
  deriving stock (Show)

spec ∷ Spec
spec = describe "R1 and R2: credits are released at the safe point, capacity refusals are never terminal" $ do
  forM_ [Cancel, ReleaseLease, CloseService] $ \how →
    it ("keeps every credit of a request whose preparation is running until the preparation has ended (" <> show how <> ")") $ do
      gate <- newDisarmedGate
      withGatedService defaultConfig alwaysAdmitting (\p → case p of PointStaging _ → True; _ → False) gate $ \svc → do
        (_, lease) <- openMain svc "main"
        _ <- readCell svc lease (tile 1 1 1)
        armGate gate
        host <- newHost True
        request <- okOf (removeWith svc (hostEndpoint svc Nothing host) lease (tile 1 1 1) Nothing)
        awaitReached gate
        held <- reserved svc
        held `shouldSatisfy` \(_, slots) → slots >= 1
        case how of
          Cancel → void (cancel svc request)
          ReleaseLease → void (releaseLease svc lease)
          CloseService → closeService svc
        -- The request has ended, but the preparation still computes with its
        -- credits: nothing was given back, and the state is coherent.
        meanwhile <- reserved svc
        meanwhile `shouldBe` held
        inspectInvariants svc >>= (`shouldBe` [])
        settled <- settledOf host
        length settled `shouldBe` 1
        openGate gate
        -- At the safe point everything returns.
        waitFor $ do
          model <- inspectModelSTM svc
          check (and [ledgerReserved (bankLedger model b) == 0 | b ← [ResidentBank, EditBank, StagingBank]] && slotInUse model CommandSlot == 0)
        settleChecks svc

  it "reconsiders a transfer refused for want of capacity as soon as capacity is returned" $ do
    exercised <- forM [2000, 2008 .. 2448] $ \headroom → do
      gate <- newDisarmedGate
      busy <- newTVarIO False
      let hold = gatedProbe (\p → case p of PointCommitted {} → True; _ → False) gate
          probe = Probe $ \point → do
            case point of
              PointHandoffBusy {} → atomically (writeTVar busy True)
              _ → pure ()
            probePoint hold point
          definition = layered [(Just 0, Just 2, "soil", 0), (Just 32, Just 34, "stone", 0)] [] ∷ SourceSpec
      withServiceUsing (microConfigWith 12 headroom) alwaysAdmitting probe $ \svc → do
        client <- okOf (registerClient svc)
        lease <- okOf (openArena svc client "pressure" definition) >>= await svc >>= expectSuccess
        _ <- readCell svc lease (tile 0 0 1)
        armGate gate
        edit <- newHost True
        _ <- okOf (removeWith svc (hostEndpoint svc Nothing edit) lease (tile 0 0 1) Nothing)
        awaitReached gate
        -- Pending reads fill the staging bank while the owner is held after the edit.
        reads' <- fillWithReads svc lease
        openGate gate
        sawBusy <-
          waitFor $ do
            model <- inspectModelSTM svc
            b <- readTVar busy
            let clean = not (any regionDirty (modelRegions model))
            check (b || clean)
            pure b
        -- Capacity returns: the pending reads end. The transfer must then be done.
        forM_ reads' (void . cancel svc)
        waitFor $ do
          model <- inspectModelSTM svc
          check (not (any regionDirty (modelRegions model)))
        settleChecks svc
        pure sawBusy
    -- The scan found staging sizes at which the transfer really was refused.
    length (filter id exercised) `shouldSatisfy` (>= 1)

-- | Admit reads that cannot be prepared yet until the model refuses another.
fillWithReads ∷ Service → ArenaLease → IO [Request]
fillWithReads svc lease = go (0 ∷ Int) []
  where
    go n acc
      | n >= 40 = pure acc
      | otherwise = do
          host <- newHost False
          cellWith svc (hostEndpoint svc Nothing host) lease (tile 0 0 1) >>= \case
            Right request → go (n + 1) (request : acc)
            Left _ → pure acc
