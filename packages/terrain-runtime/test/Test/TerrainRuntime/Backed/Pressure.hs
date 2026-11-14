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
import Hetoimasia.Terrain.Runtime hiding (Snapshot)
import Hetoimasia.Terrain.Runtime.Settlement
import Hetoimasia.Terrain.Runtime.Storage.Internal.Native (NativeOp (..))
import Hetoimasia.Terrain.Runtime.Storage.Internal.Service (BackingSnap (..), HeldSnap (..), JobKind (..), JobSnap (..), SlotTag (..), Snapshot (..))
import Hetoimasia.Terrain.Runtime.Store.Admission (Ledger (..))
import qualified Data.Map.Strict as Map
import Hetoimasia.Terrain.Runtime.Storage.Internal.Types (Errno (..))
import Test.Hspec
import System.Timeout (timeout)
import Test.Support.Bounded (boundMicroseconds)
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
spec = do
  describe "Temporary pressure from the storage service" $
    forM_ [minBound .. maxBound] $ \caller →
      it ("keeps a " <> show caller <> " refused because the storage queue is full in its place, grants nothing again until capacity changes, and completes it once the queue drains") (pressureCase caller)
  describe "The storage pressure mark" $
    it "holds every field a refusal for pressure reads: the cure of each reason alone changes it" $ do
      let base = markOf snapshot ledger
      markOf snapshot ledger `shouldBe` base
      forM_ cures $ \(cure, sn, l) → (cure, markOf sn l /= base) `shouldBe` (cure, True)

-- | A storage service under pressure: a read running and a write queued (the mutation), a backing
-- growing with an extra pending, a closing record, a presecured open, a held close, kept failures,
-- and an edit bank with pinned cache.
snapshot ∷ Snapshot
snapshot =
  Snapshot
    { snJobs = [readJob, writeJob]
    , snBackings = [backing]
    , snClosing = 1
    , snClosingCharged = 1
    , snClosingRecs = []
    , snOpening = [(9, Nothing)]
    , snHeld = [HeldSnap 2 1 0 4]
    , snWorkers = 2
    , snAdmissionOpen = True
    , snStopReason = Nothing
    , snEvidence = 3
    , snEvidenceDropped = 0
    , snReserved = Map.empty
    , snQueued = 8
    , snRunning = 2
    , snMutation = Just 8
    , snBusyVolumes = 0
    }

readJob, writeJob ∷ JobSnap
readJob = JobSnap {jsId = 7, jsKind = KRead 1, jsPhase = 2, jsBacking = Just 1, jsBorrowed = 0, jsPrepared = Nothing, jsHoldsResult = True, jsCharge = 4096, jsDelivered = False}
writeJob = readJob {jsId = 8, jsKind = KWrite, jsPhase = 0, jsHoldsResult = False, jsCharge = 4096 + 112 + 512}

backing ∷ BackingSnap
backing = BackingSnap {bsId = 1, bsSlot = SlotRunning, bsPending = Just (128 * 1024 * 1024), bsReserved = 64 * 1024 * 1024, bsAllocated = 64 * 1024 * 1024, bsVolume = 1, bsBorrows = 0, bsClosing = False, bsFd = 3}

ledger ∷ Ledger
ledger = Ledger {lgCacheLimit = 50331648, lgCacheBacked = 100000, lgCacheRamOnly = 20000, lgCachePinned = 60000, lgStagingLimit = 8388608, lgStagingForeground = 8320, lgStagingCamera = 0, lgControlLimit = 8388608, lgControlReserved = 24576}

-- | Each reason's cure, alone.
cures ∷ [(String, Snapshot, Ledger)]
cures =
  [ ("QueueFull: a queued job taken", snapshot {snQueued = 7}, ledger)
  , ("RecordsFull: a job record collected", snapshot {snJobs = [readJob]}, ledger)
  , ("RecordsFull: a finished job's result taken", snapshot {snJobs = [readJob {jsHoldsResult = False}, writeJob]}, ledger)
  , ("MutationActive: the mutation ended", snapshot {snMutation = Nothing}, ledger)
  , ("GrowthActive: the growth slot idle", snapshot {snBackings = [backing {bsSlot = SlotIdle}]}, ledger)
  , ("GrowthActive: the pending extra released", snapshot {snBackings = [backing {bsPending = Nothing}]}, ledger)
  , ("CachePressure: an unpin, the entry kept", snapshot, ledger {lgCachePinned = 0})
  , ("CachePressure: an entry dropped", snapshot, ledger {lgCacheBacked = 95136})
  , ("StagingPressure: a transfer buffer returned", snapshot, ledger {lgStagingForeground = 0})
  , ("ControlPressure: a record's grant returned", snapshot, ledger {lgControlReserved = 20480})
  , ("ControlPressure: a closing record ended", snapshot {snClosing = 0, snClosingCharged = 0}, ledger)
  , ("ControlPressure: a presecured open settled", snapshot {snOpening = []}, ledger)
  ]

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
    others ← newTVarIO ([] ∷ [Host])
    -- every wait names itself when its bound is hit, with what the storage service and the owner hold
    let diagnosis = do
          queued ← atomically (inspectStorageQueuedSTM svc)
          pressed ← atomically (inspectStoragePressedSTM svc)
          granted ← readTVarIO grants
          pendingBytes ← either (const Nothing) (Just . statusPendingReservedBytes) <$> atomically (arenaStatusSTM svc lease)
          own ← settledOf host
          rest ← readTVarIO others >>= mapM settledOf
          defects ← inspectDefects svc
          pure ("queued " <> show queued <> ", pressed " <> show pressed <> ", grants " <> show granted <> ", pending bytes " <> show pendingBytes <> ", the caller settled " <> show own <> ", the others settled " <> show rest <> ", defects " <> show defects)
        named ∷ String → STM a → IO a
        named what stm = timeout boundMicroseconds (atomically stm) >>= \case
          Just a → pure a
          Nothing → diagnosis >>= \d → fail ("the wait for " <> what <> " was not satisfied within its bound: " <> d)
        answered ∷ String → IO b → IO b
        answered what action = timeout boundMicroseconds action >>= \case
          Just b → pure b
          Nothing → diagnosis >>= \d → fail ("the wait for " <> what <> " was not satisfied within its bound: " <> d)
    -- what must exist before the queue fills: a removal staged and waiting for its host, or an extra
    -- left pending by a growth whose host withdrew and whose release failed
    case caller of
      Transaction → do
        _ ← okOf (removeWith svc (hostEndpoint svc Nothing host) lease (tile 7 7 7) Nothing)
        named "the removal staged" (readTVar (hostReady host) >>= \n → check (n >= 1))
      Release → do
        reserve ← H.addGateOnce probe isReserve
        H.addRuleAfter probe 1 1 isSetLength (H.FailWith (Errno 5))
        grower ← newHost True
        atomically (modifyTVar' others (grower :))
        flip finally (H.openGate reserve) $ do
          g ← okOf (growWith svc (hostEndpoint svc Nothing grower) lease (toInteger (128 * mib)))
          atomically (writeTVar pendingGrowth (Just g))
          named "the growth's reservation at the seam" (readTVar (H.gReached reserve) >>= check . (>= 1))
          atomically (writeTVar (hostEligible grower) False)
        named "the growth's extra left pending" (arenaStatusSTM svc lease >>= either (const retry) (check . (> 0) . statusPendingReservedBytes))
      _ → pure ()
    named "rest before the queue fills" (backedAtRestSTM svc >>= check)
    gate ← H.addGate probe isRead
    fillers ← flip finally (H.openGate gate) $ do
      fillers ← forM [0 .. 13] $ \x → do
        h ← newHost True
        _ ← okOf (removeWith svc (hostEndpoint svc Nothing h) lease (tile x 4 3) Nothing)
        atomically (modifyTVar' others (h :))
        pure h
      named "two reads at the seam" (readTVar (H.gReached gate) >>= check . (>= 2))
      named "the queue full" (inspectStorageQueuedSTM svc >>= check . (>= 8))
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
      named "the refusal noted" (inspectStoragePressedSTM svc >>= check)
      -- two attaches admitted after, one after the other, are answered: each is prepared and
      -- committed, so the owner's turn order reaches its backed turn (where a grant would be made)
      -- between them
      when (caller /= Open) $ forM_ [1 ∷ Int, 2] $ \_ → do
        other ← okOf (registerClient svc)
        void (answered "an attach answered" (okOf (attachArena svc other "main") >>= await svc) >>= expectSuccess)
      -- nothing of it settled, nothing ended the owner, and nothing was granted again at once
      readTVarIO (hostSettled host) `shouldReturn` []
      inspectDefects svc `shouldReturn` []
      -- exactly the one grant that met the full queue; an open is never granted
      readTVarIO grants `shouldReturn` (if caller == Open then 0 else 1)
      pure fillers
    -- the reads are let go: the caller completes
    forM_ (host : fillers) $ \h → named "every caller settled once the reads are let go" (readTVar (hostSettled h) >>= \s → check (not (null s)))
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
    named "rest at the end" (backedAtRestSTM svc >>= check)
    settleChecks svc
