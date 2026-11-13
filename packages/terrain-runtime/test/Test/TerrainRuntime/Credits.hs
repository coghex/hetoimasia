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
import Control.Exception (finally)
import Control.Monad (forM_, void)
import Data.Text (pack)
import Hetoimasia.Terrain.Residency
import Hetoimasia.Terrain.Runtime
import Hetoimasia.Terrain.Runtime.Settlement
import qualified Hetoimasia.Terrain.Runtime.Store.Internal.Admission as A
import Hetoimasia.Terrain.Runtime.Store.Internal.Plan (RamCharge (..))
import Hetoimasia.Terrain.Runtime.Storage.Internal.Native (NativeOp (..))
import Hetoimasia.Terrain.Runtime.Storage.Internal.Service (resultPageBytes)
import Test.Hspec
import Test.TerrainRuntime.Fixtures
import qualified Test.TerrainRuntime.Storage.Harness as H

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

  -- (the baseline's 'reconsiders a transfer refused for want of capacity': a backed commit transfers
  -- nothing; the work refused for want of capacity is the slot's grant, refused while readers' reads
  -- hold the edit bank's cache, and reconsidered when they return it)
  it "reconsiders a grant refused for want of capacity as soon as the readers return it, and keeps nothing when the arena ends, across incarnations" $ do
    let need = toInteger (ramDecodedCopies A.worstTransactionCharge) + 2 * toInteger A.readerPinnedCacheBytes + toInteger resultPageBytes
        config = defaultConfig {configMaxArenas = 1, configEditBank = A.defaultEditBankSpec {A.ebsCache = need, A.ebsArenas = 1, A.ebsReadersPerArena = 2}}
    granted ← newTVarIO (0 ∷ Int)
    probe ← H.newProbe
    let owner = Probe $ \case
          PointGranted (Just _) _ → atomically (modifyTVar' granted (+ 1))
          _ → pure ()
    withServiceSeam quiet config alwaysAdmitting owner (H.seamFor probe) $ \svc → do
      client ← okOf (registerClient svc)
      -- several incarnations on one service: nothing about a refused grant may accumulate
      forM_ [1 .. 3 ∷ Int] $ \cycle' → do
        lease ← okOf (openArena svc client (pack ("pressure" <> show cycle')) soilOverStone) >>= await svc >>= expectSuccess
        _ ← removeCell' svc lease (tile 3 4 9)
        backedAtRest svc
        edit ← newHost False
        _ ← okOf (removeWith svc (hostEndpoint svc Nothing edit) lease (tile 3 4 5) Nothing)
        waitFor (readTVar (hostReady edit) >>= \n → check (n >= 1))
        backedAtRest svc
        grantsBefore ← readTVarIO granted
        gate ← H.addGate probe isRead
        readers ← flip finally (H.openGate gate) $ do
          readers ← mapM (\at → okOf (cellAt svc lease at)) [tile 8 8 8, tile 9 9 9]
          H.awaitReached gate 2
          -- the edit becomes eligible: its grant is refused for want of the cache the reads hold
          atomically (writeTVar (hostEligible edit) True)
          readTVarIO granted `shouldReturn` grantsBefore
          pure readers
        -- the reads return the cache: the grant is reconsidered and the edit commits
        mapM_ (await svc) readers
        _ ← waitFor (readTVar (hostSettled edit) >>= \s' → if null s' then retry else pure s')
        settledOf edit >>= (`shouldSatisfy` \case [Succeeded (ARemoved r)] → removeChangedFlag r; _ → False)
        readTVarIO granted >>= (`shouldSatisfy` (> grantsBefore))
        settleChecks svc
        -- the incarnation ends: nothing of it remains
        _ ← releaseLease svc lease
        waitFor $ do
          model ← inspectModelSTM svc
          check (null (modelArenas model))
        backedAtRest svc
        settleChecks svc

  -- (the baseline's 'remembers nothing about a transfer whose arena ended while it was in flight')
  it "remembers nothing about a transaction whose arena ended while its write was in flight" $ do
    probe ← H.newProbe
    withServiceSeam quiet defaultConfig alwaysAdmitting noProbe (H.seamFor probe) $ \svc → do
      (_, lease) ← openMain svc "main"
      _ ← readCell svc lease (tile 1 1 1)
      backedAtRest svc
      gate ← H.addGate probe isWrite
      flip finally (H.openGate gate) $ do
        _ ← okOf (removeAt svc lease (tile 1 1 1) Nothing)
        -- the owner's transaction is in the middle of its write
        H.awaitReached gate 1
        _ ← releaseLease svc lease
        pure ()
      waitFor $ do
        model ← inspectModelSTM svc
        check (null (modelArenas model) && null (modelRegions model))
      backedAtRest svc
      inspectBacked svc `shouldReturn` []
      settleChecks svc

  where
    isRead, isWrite ∷ NativeOp → Bool
    isRead = \case OpReadAt {} → True; _ → False
    isWrite = \case OpWriteAt {} → True; _ → False
    backedAtRest svc = waitFor (backedAtRestSTM svc >>= check)
