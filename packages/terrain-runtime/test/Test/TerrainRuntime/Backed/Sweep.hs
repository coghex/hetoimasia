-- | ONE sweep of a removal's resource-ending paths through the production backed service
-- (lesson h): every step at which a removal can hold something, crossed with every way it can
-- end there, with an oracle of the physical truth after every step.
--
-- Steps (where the removal is held when the exit happens):
--
-- * @staged@: its staging read has finished and it waits for its host's eligibility (it holds a
--   command slot, its result record and the model's reservations; no pin, no transaction).
-- * @reading@: its staging read is in flight, held at the native seam (a reader pin and a read job).
-- * @writing@: it holds the session's slot and its write is in flight, held at the native seam
--   (a transaction claim, its credits, a write job).
--
-- Exits: a cancellation, the release of the creator's lease (the arena closes), the service's
-- close, a native failure of the held call, and the commit (the gate opened, the host granted).
--
-- The oracle, after the exit and again once the held call has returned: the service's invariants,
-- the backed oracle ('inspectBacked': pins against gathers, the store's transaction against the
-- slot, the compile account against its holders, the backend's files against the arenas, the edit
-- bank at rest with nothing in flight), the edit bank's ledgers back at zero, and the terrain the
-- store holds read back: unchanged unless the commit won.
module Test.TerrainRuntime.Backed.Sweep (spec) where

import Control.Concurrent.STM
import Control.Monad (forM_, when)
import Hetoimasia.Terrain.Runtime
import Hetoimasia.Terrain.Runtime.Settlement
import Hetoimasia.Terrain.Runtime.Store.Admission (Ledger (..))
import Hetoimasia.Terrain.Runtime.Storage.Internal.Native (NativeOp (..))
import Hetoimasia.Terrain.Runtime.Storage.Internal.Types (Errno (..))
import Test.Hspec
import Test.TerrainRuntime.Fixtures
import qualified Test.TerrainRuntime.Storage.Harness as H

data Step = Staged | Reading | Writing
  deriving stock (Eq, Show, Enum, Bounded)

data Exit = ByCancel | ByLeaseRelease | ByServiceClose | ByNativeFailure | ByCommit
  deriving stock (Eq, Show, Enum, Bounded)

isWrite, isRead ∷ NativeOp → Bool
isWrite = \case OpWriteAt {} → True; _ → False
isRead = \case OpReadAt {} → True; _ → False

-- | The edit bank holds nothing of the owner's: no pin, no transaction, no staging.
bankAtRest ∷ Service → IO ()
bankAtRest svc = waitFor $ do
  bank ← inspectEditBankSTM svc
  check (lgStagingForeground bank == 0 && lgControlReserved bank == 0 && lgCachePinned bank == 0)

oracle ∷ Service → IO ()
oracle svc = do
  inspectInvariants svc >>= (`shouldBe` [])
  inspectBacked svc >>= (`shouldBe` [])

spec ∷ Spec
spec = describe "The backed removal's ending paths (sweep)" $
  forM_ [minBound .. maxBound] $ \step → forM_ [minBound .. maxBound] $ \exit →
    it ("held " <> show step <> ", ended " <> show exit) (sweepCase step exit)

sweepCase ∷ Step → Exit → IO ()
sweepCase step exit = do
  probe ← H.newProbe
  withServiceSeam quiet defaultConfig alwaysAdmitting noProbe (H.seamFor probe) $ \svc → do
    (client, lease) ← openMain svc "main"
    -- history in the cell's column, so that its staging read has a page to read
    _ ← removeCell' svc lease (tile 3 4 9)
    let target = tile 3 4 5
        held = case step of
          Staged → Nothing
          Reading → Just isRead
          Writing → Just isWrite
    -- a failure is injected at the held call; otherwise the call is held at a gate
    gate ← case (held, exit) of
      (Just match, ByNativeFailure) → H.addRule probe 1 match (H.FailWith (Errno 5)) >> pure Nothing
      (Just match, _) → Just <$> H.addGate probe match
      (Nothing, _) → pure Nothing
    host ← newHost (step /= Staged)
    request ← okOf (removeWith svc (hostEndpoint svc Nothing host) lease target Nothing)
    -- reach the step
    case (step, gate) of
      (Staged, _) → waitFor (readTVar (hostReady host) >>= \n → check (n >= 1))
      (_, Just g) → H.awaitReached g 1
      (_, Nothing) → pure ()
    oracle svc
    -- the exit
    case exit of
      ByCancel → cancel svc request `shouldReturn` CancelWon
      ByLeaseRelease → endClient svc client
      ByServiceClose → closeService svc
      ByNativeFailure → when (step == Staged) (grant host)
      ByCommit → grant host
    forM_ gate H.openGate
    -- the request ends once
    settled ← waitFor (readTVar (hostSettled host) >>= \s → if null s then retry else pure s)
    length settled `shouldBe` 1
    let committed = case settled of
          [Succeeded (ARemoved _)] → True
          _ → False
    case exit of
      ByCommit → committed `shouldBe` True
      ByCancel → settled `shouldBe` [Cancelled]
      ByLeaseRelease → settled `shouldSatisfy` (`elem` [[Failed ArenaClosed], [Cancelled]])
      ByServiceClose → settled `shouldSatisfy` (`elem` [[Failed ArenaClosed], [Cancelled]])
      ByNativeFailure → committed `shouldBe` (step == Staged)
    -- once nothing is in flight: the oracle, the bank at rest, and the store's terrain
    bankAtRest svc
    oracle svc
    when (exit /= ByLeaseRelease && exit /= ByServiceClose) $ do
      found ← readCell svc lease target
      cellIs found `shouldBe` committed
