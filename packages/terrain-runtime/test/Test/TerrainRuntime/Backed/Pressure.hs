-- | Temporary pressure from the storage service never settles a request or ends the owner, and is
-- never retried at once: a caller refused for it keeps its place and waits for the service's
-- capacity to change.
--
-- Every example fills the storage service deterministically: every page read is held at the seam,
-- so its two workers hold two reads and eight more wait in its queue (it takes no more). Then one
-- caller of the service acts, and its first job is refused for that pressure. While the reads are
-- held nothing of the caller settles, no defect is recorded and a transaction is granted at most
-- once; when they are let go, the caller completes.
module Test.TerrainRuntime.Backed.Pressure (spec) where

import Control.Concurrent.STM
import Control.Exception (finally)
import Control.Monad (forM, forM_, void, when)
import Data.Word (Word64)
import Hetoimasia.Terrain.Runtime
import Hetoimasia.Terrain.Runtime.Settlement
import Hetoimasia.Terrain.Runtime.Storage.Internal.Native (NativeOp (..))
import Hetoimasia.Terrain.Runtime.Storage.Internal.Types (Errno (..))
import Test.Hspec
import Test.TerrainRuntime.Fixtures
import qualified Test.TerrainRuntime.Storage.Harness as H

-- | The caller whose first job meets the full queue.
data Caller
  = -- | a staged removal made eligible: the slot's transaction
    Transaction
  | -- | a growth: its reservation
    Growth
  | -- | a retry releasing an extra a failed growth left pending: the release
    Release
  | -- | an open of a new arena: its reservation, once compiled
    Open
  deriving stock (Eq, Show, Enum, Bounded)

mib ∷ Word64
mib = 1024 * 1024

isRead, isReserve, isSetLength ∷ NativeOp → Bool
isRead = \case OpReadAt {} → True; _ → False
isReserve = \case OpReserveRange {} → True; _ → False
isSetLength = \case OpSetFileLength {} → True; _ → False

spec ∷ Spec
spec = describe "Temporary pressure from the storage service" $
  forM_ [minBound .. maxBound] $ \caller →
    it ("keeps a " <> show caller <> " refused because the storage queue is full in its place, grants nothing again until capacity changes, and completes it once the queue drains") (pressureCase caller)

pressureCase ∷ Caller → IO ()
pressureCase caller = do
  probe ← H.newProbe
  grants ← newTVarIO (0 ∷ Int)
  let owner = Probe $ \case
        PointGranted (Just _) _ → atomically (modifyTVar' grants (+ 1))
        _ → pure ()
  withServiceSeam quiet defaultConfig alwaysAdmitting owner (H.seamFor probe) $ \svc → do
    (client, lease) ← openMain svc "main"
    forM_ [(3, 4, 9), (5, 4, 9)] $ \(x, y, z) → removeCell' svc lease (tile x y z)
    waitFor (backedAtRestSTM svc >>= check)
    host ← newHost (caller /= Transaction)
    pendingGrowth ← newTVarIO Nothing
    -- what must exist before the queue fills: a removal staged and waiting for its host, or an extra
    -- left pending by a growth whose host withdrew and whose release failed
    case caller of
      Transaction → do
        _ ← okOf (removeWith svc (hostEndpoint svc Nothing host) lease (tile 7 7 7) Nothing)
        waitFor (readTVar (hostReady host) >>= \n → check (n >= 1))
      Release → do
        reserve ← H.addGateOnce probe isReserve
        H.addRuleAfter probe 1 1 isSetLength (H.FailWith (Errno 5))
        grower ← newHost True
        flip finally (H.openGate reserve) $ do
          g ← okOf (growWith svc (hostEndpoint svc Nothing grower) lease (toInteger (128 * mib)))
          atomically (writeTVar pendingGrowth (Just g))
          H.awaitReached reserve 1
          atomically (writeTVar (hostEligible grower) False)
        waitFor (arenaStatusSTM svc lease >>= either (const retry) (check . (> 0) . statusPendingReservedBytes))
      _ → pure ()
    waitFor (backedAtRestSTM svc >>= check)
    gate ← H.addGate probe isRead
    fillers ← flip finally (H.openGate gate) $ do
      fillers ← forM [0 .. 13] $ \x → do
        h ← newHost True
        _ ← okOf (removeWith svc (hostEndpoint svc Nothing h) lease (tile x 4 3) Nothing)
        pure h
      H.awaitReached gate 2
      waitFor (inspectStorageQueuedSTM svc >>= check . (>= 8))
      atomically (writeTVar grants 0)
      -- the caller acts while the queue is full
      case caller of
        Transaction → grant host
        Growth → void (okOf (growWith svc (hostEndpoint svc Nothing host) lease (toInteger (128 * mib))))
        Release → void (okOf (retryWith svc (hostEndpoint svc Nothing host) lease))
        Open → void (okOf (openArenaWith svc (hostEndpoint svc Nothing host) client "other" soilOverStone))
      -- the caller was refused for the pressure, and the owner noted it; then an attach admitted after
      -- is answered (several turns of the owner, the grant's among them; an open's own attach would
      -- wait behind it, so an open is not followed by one)
      waitFor (inspectStoragePressedSTM svc >>= check)
      when (caller /= Open) $ do
        other ← okOf (registerClient svc)
        void (okOf (attachArena svc other "main") >>= await svc >>= expectSuccess)
      -- nothing of it settled, nothing ended the owner, and nothing was granted again at once
      readTVarIO (hostSettled host) `shouldReturn` []
      inspectDefects svc `shouldReturn` []
      readTVarIO grants >>= (`shouldSatisfy` (<= 1))
      pure fillers
    -- the reads are let go: the caller completes
    forM_ (host : fillers) $ \h → waitFor (readTVar (hostSettled h) >>= \s → check (not (null s)))
    settledOf host >>= \outcome → case (caller, outcome) of
      (Transaction, [Succeeded (ARemoved r)]) → removeChangedFlag r `shouldBe` True
      (Growth, [Succeeded (AGrown a)]) → grownAllowance a `shouldBe` 128 * mib
      (Release, [Succeeded (ARetried a)]) → retriedRemaining a `shouldBe` []
      (Open, [Succeeded _]) → pure ()
      _ → expectationFailure ("the caller settled " <> show outcome)
    -- the growth that left its extra pending still waits for its host: it is cancelled
    readTVarIO pendingGrowth >>= mapM_ (\g → cancel svc g `shouldReturn` CancelWon)
    status ← arenaStatus svc lease >>= expectRight
    statusPendingReservedBytes status `shouldBe` 0
    inspectDefects svc `shouldReturn` []
    waitFor (backedAtRestSTM svc >>= check)
    settleChecks svc
