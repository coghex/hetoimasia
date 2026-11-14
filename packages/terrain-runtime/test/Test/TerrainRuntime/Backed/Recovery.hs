-- | Recovery is decided like publication, and a pending extra has one owner.
--
-- * A condition's record keeps every failing operation and page (bounded), with a generation a new
--   failure moves: a retry certifies a condition only by re-testing every failure recorded for it,
--   and a failure recorded while its probe is in flight makes the probe's result stale.
-- * A failed write is not re-tested by a read: a condition with a failed write is never certified by
--   the read probe.
-- * The clearing commits in the retry's arbitration, with its host's eligibility and its settlement:
--   a retry that is not eligible, or is cancelled, clears nothing.
-- * Once an arena pauses, ordinary work in flight does not publish.
-- * A probe's own failure keeps its classification: a worker failure reaches supervision.
-- * A growth that ends before it is prepared, its extra's give-back failed, leaves the store
--   releasing exactly what the backend keeps pending, and the status counts that extra once.
module Test.TerrainRuntime.Backed.Recovery (spec) where

import Control.Concurrent.STM
import Control.Exception (finally)
import Control.Monad (void)
import Data.Word (Word64)
import Hetoimasia.Terrain.Coordinate (TileCoord)
import Hetoimasia.Terrain.Runtime
import Hetoimasia.Terrain.Runtime.Settlement
import Hetoimasia.Terrain.Runtime.Storage.Internal.Native (NativeOp (..))
import Hetoimasia.Terrain.Runtime.Storage.Internal.Types (Errno (..), IoFailure (..))
import Test.Hspec
import Test.Support.Bounded (bounded)
import Test.TerrainRuntime.Fixtures hiding (limitsWith)
import qualified Test.TerrainRuntime.Storage.Harness as H
import Test.TerrainRuntime.Store.Scenes (Scene (..), limitsWith, openingA, twoOpenings)

mib ∷ Word64
mib = 1024 * 1024

isRead, isWrite, isReserve, isSetLength ∷ NativeOp → Bool
isRead = \case OpReadAt {} → True; _ → False
isWrite = \case OpWriteAt {} → True; _ → False
isReserve = \case OpReserveRange {} → True; _ → False
isSetLength = \case OpSetFileLength {} → True; _ → False

-- | A read of this page's offset.
readAt ∷ Word64 → NativeOp → Bool
readAt off = \case OpReadAt o _ → o == off; _ → False

-- | The offsets of the pages a read of this cell reads from the file, in the order it reads them
-- (each once): the pages a failure can be injected at.
pagesRead ∷ H.Probe → Service → ArenaLease → TileCoord → IO [Word64]
pagesRead probe svc lease at = do
  H.clearEvents probe
  _ ← readCell svc lease at
  ops ← H.events probe
  pure (dedupe [o | OpReadAt o _ ← ops])
  where
    dedupe = foldr (\x acc → x : filter (/= x) acc) []

pausedOn ∷ Service → ArenaLease → IO [Condition]
pausedOn svc lease = do
  status ← arenaStatus svc lease >>= expectRight
  pure $ case statusStorage status of
    StoragePaused conditions → conditions
    StorageReady → []

-- | A service whose backend's native calls pass a harness probe, with one arena whose store holds
-- history in 256 columns (so its tree has several pages, and a read of column (3, 4) reads more than
-- one).
withTree ∷ (H.Probe → Service → ArenaLease → IO ()) → IO ()
withTree = withArenaOf [(x, y) | x ← [0 .. 15], y ← [0 .. 15]]

-- | One removal at (3, 4, 5): a read of column (3, 4) reads the store's one page.
withArena ∷ (H.Probe → Service → ArenaLease → IO ()) → IO ()
withArena = withArenaOf [(3, 4)]

withArenaOf ∷ [(Integer, Integer)] → (H.Probe → Service → ArenaLease → IO ()) → IO ()
withArenaOf columns body = do
  probe ← H.newProbe
  withServiceSeam quiet defaultConfig alwaysAdmitting noProbe (H.seamFor probe) $ \svc → do
    (_, lease) ← openMain svc "main"
    mapM_ (\(x, y) → removeCell' svc lease (tile x y 5)) columns
    waitFor (backedAtRestSTM svc >>= check)
    body probe svc lease

-- | A write of this page's offset.
writeAt ∷ Word64 → NativeOp → Bool
writeAt off = \case OpWriteAt o _ → o == off; _ → False

-- | A removal whose first page write fails, pausing the arena storage_io: the failing write's offset.
failWrite ∷ H.Probe → Service → ArenaLease → IO Word64
failWrite probe svc lease = do
  H.addRule probe 1 isWrite (H.FailWith (Errno 5))
  failed ← removeAt svc lease (tile 3 4 4) Nothing >>= expectRight >>= bounded . await svc
  pausedOn svc lease `shouldReturn` [CondIo]
  case failed of
    Left (Failed (StorageFailed (FaultIo io))) | Just off ← ioOffset io → pure off
    other → expectationFailure ("expected a write's storage_io, got " <> show other) >> fail "unreachable"

-- | A read of the column that fails, pausing the arena storage_io.
failRead ∷ Service → ArenaLease → IO ()
failRead svc lease = do
  failed ← cellAt svc lease (tile 3 4 6) >>= expectRight >>= bounded . await svc
  failed `shouldSatisfy` \case Left (Failed (StorageFailed (FaultIo _))) → True; _ → False

retryAnswer ∷ Service → ArenaLease → IO (Either Settlement RetryAnswer)
retryAnswer svc lease = retryArena svc lease >>= expectRight >>= bounded . await svc

spec ∷ Spec
spec = describe "Recovery decided like publication" $ do
  it "keeps both of two pages that failed, and does not certify the condition while either still fails" $
    withTree $ \probe svc lease → do
      -- the header page fails first, then (while paused, reads go on) another page of the tree
      pages ← pagesRead probe svc lease (tile 3 4 6)
      (first, lastPage) ← case pages of
        a : rest@(_ : _) → pure (a, last rest)
        _ → expectationFailure ("a read of the column reads fewer than two pages: " <> show pages) >> fail "unreachable"
      -- the first page fails; then (while paused, reads go on) the first reads back and the last fails
      H.addRule probe 1 (readAt first) (H.FailWith (Errno 5))
      failRead svc lease
      H.addRule probe 1 (readAt lastPage) (H.FailWith (Errno 5))
      failRead svc lease
      pausedOn svc lease `shouldReturn` [CondIo]
      -- the first page reads back now, the last does not
      H.addRule probe (-1) (readAt lastPage) (H.FailWith (Errno 5))
      answer ← retryAnswer svc lease
      fmap (\a → (retriedCleared a, retriedRemaining a)) answer `shouldBe` Right ([], [CondIo])
      pausedOn svc lease `shouldReturn` [CondIo]

  it "re-tests a failed write by writing its page again: the condition stays while that page's write keeps failing, though reads succeed" $
    withArena $ \probe svc lease → do
      offset ← failWrite probe svc lease
      -- every later write of that page fails too
      H.addRule probe (-1) (writeAt offset) (H.FailWith (Errno 5))
      answer ← retryAnswer svc lease
      fmap (\a → (retriedCleared a, retriedRemaining a)) answer `shouldBe` Right ([], [CondIo])
      pausedOn svc lease `shouldReturn` [CondIo]

  it "certifies a failed write once its page takes a write again, writing and reading it back without publishing anything, and edits commit again" $
    withArena $ \probe svc lease → do
      offset ← failWrite probe svc lease
      H.clearEvents probe
      answer ← retryAnswer svc lease
      fmap (\a → (retriedCleared a, retriedRemaining a)) answer `shouldBe` Right ([CondIo], [])
      -- the probe wrote the page and read it back
      ops ← H.events probe
      ([() | OpWriteAt o _ ← ops, o == offset], [() | OpReadAt o _ ← ops, o == offset]) `shouldSatisfy` (\(w, r) → not (null w) && not (null r))
      pausedOn svc lease `shouldReturn` []
      _ ← removeCell' svc lease (tile 3 4 3)
      pure ()

  it "keeps no more than eight failures of a condition, and then answers it remaining until the arena is closed, never probing it" $
    withTree $ \probe svc lease → do
      -- a second run in every column: the tree has more leaves
      mapM_ (\(x, y) → removeCell' svc lease (tile x y 2)) [(x, y) | x ← [0 .. 15], y ← [0 .. 15]]
      waitFor (backedAtRestSTM svc >>= check)
      -- nine distinct pages, each one a column's read reads
      paths ← mapM (\(x, y) → fmap (\ps → [(o, (x, y)) | o ← ps]) (pagesRead probe svc lease (tile x y 6))) [(x, y) | x ← [0, 3 .. 15], y ← [0, 3 .. 15]]
      let distinct = take 9 (foldl (\acc (o, x) → if any ((== o) . fst) acc then acc else acc <> [(o, x)]) [] (concat paths))
      length distinct `shouldBe` 9
      mapM_ (\(o, x) → do
                H.addRule probe 1 (readAt o) (H.FailWith (Errno 5))
                failed ← cellAt svc lease (tile (fst x) (snd x) 6) >>= expectRight >>= bounded . await svc
                failed `shouldSatisfy` \case Left (Failed (StorageFailed (FaultIo _))) → True; _ → False)
        distinct
      H.clearEvents probe
      answer ← retryAnswer svc lease
      fmap (\a → (retriedCleared a, retriedRemaining a, retriedUntilClosed a)) answer `shouldBe` Right ([], [CondIo], [CondIo])
      -- nothing was probed
      ops ← H.events probe
      [o | OpReadAt o _ ← ops, o `elem` map fst distinct] `shouldBe` []
      -- the arena stays readable
      _ ← readCell svc lease (tile 9 9 9)
      pausedOn svc lease `shouldReturn` [CondIo]

  it "ends the owner with a defect when a retry's write probe meets a worker failure" $
    withArena $ \probe svc lease → do
      offset ← failWrite probe svc lease
      H.addRule probe 1 (writeAt offset) H.Throw
      host ← newHost True
      _ ← okOf (retryWith svc (hostEndpoint svc Nothing host) lease)
      bounded (awaitOwnerStopped svc)
      inspectDefects svc >>= (`shouldSatisfy` (not . null))
      settledOf host >>= (`shouldSatisfy` \case [Succeeded (ARetried _)] → False; _ → True)

  it "clears nothing for a retry whose host is not eligible, nor for one that is cancelled, and clears once one is answered" $
    withArena $ \probe svc lease → do
      H.addRule probe 1 isRead (H.FailWith (Errno 5))
      failRead svc lease
      host ← newHost False
      request ← okOf (retryWith svc (hostEndpoint svc Nothing host) lease)
      -- the probe has passed and the answer is staged: the host was told it is ready
      waitFor (readTVar (hostReady host) >>= \n → check (n >= 1))
      pausedOn svc lease `shouldReturn` [CondIo]
      cancel svc request `shouldReturn` CancelWon
      pausedOn svc lease `shouldReturn` [CondIo]
      answer ← retryAnswer svc lease
      fmap (\a → (retriedCleared a, retriedRemaining a)) answer `shouldBe` Right ([CondIo], [])
      pausedOn svc lease `shouldReturn` []

  it "does not publish discovery that was in flight when its arena paused" $ do
    probe ← H.newProbe
    -- once armed, the next grant to discovery (one unit of it per transaction) installs a gate on every
    -- write, so that transaction's write is held at the seam
    armed ← newTVarIO False
    gateVar ← newEmptyTMVarIO
    published ← newTVarIO (0 ∷ Int)
    let owner = Probe $ \case
          PointDiscoveryCommitted _ → atomically (modifyTVar' published (+ 1))
          PointDiscoveryGranted _ → do
            now ← atomically ((&&) <$> readTVar armed <*> isEmptyTMVar gateVar)
            if now then H.addGate probe isWrite >>= atomically . putTMVar gateVar else pure ()
          _ → pure ()
    withServiceSeam quiet defaultConfig {configDiscovery = limitsWith 1} alwaysAdmitting owner (H.seamFor probe) $ \svc → do
      client ← okOf (registerClient svc)
      lease ← okOf (openArena svc client "cave" (sceneSpec twoOpenings)) >>= await svc >>= expectSuccess
      -- the opening leaves discovery obligations behind, more than one transaction's worth
      mapM_ (\(x, y, z) → removeCell' svc lease (tile x y z)) openingA
      status ← arenaStatus svc lease >>= expectRight
      (statusDiscovery status, statusPendingItems status >= 2) `shouldBe` (DiscoveryPending, True)
      atomically (writeTVar armed True)
      held ← atomically (readTMVar gateVar)
      flip finally (H.openGate held) $ do
        H.awaitReached held 1
        statusBefore ← arenaStatus svc lease >>= expectRight
        publishedBefore ← readTVarIO published
        -- a read of the arena fails: it pauses while discovery's write is in flight
        H.addRule probe 1 isRead (H.FailWith (Errno 5))
        let (ox, oy, oz) = case openingA of c : _ → c; [] → (0, 0, 0)
        failed ← cellAt svc lease (tile ox oy (oz + 1)) >>= expectRight >>= bounded . await svc
        failed `shouldSatisfy` \case Left (Failed (StorageFailed _)) → True; _ → False
        pausedOn svc lease `shouldReturn` [CondIo]
        H.openGate held
        waitFor (backedAtRestSTM svc >>= check)
        statusAfter ← arenaStatus svc lease >>= expectRight
        -- no discovery transaction published after the pause: not the held one, nor any other
        readTVarIO published `shouldReturn` publishedBefore
        (statusKnowledgeRevision statusAfter, statusDiscovery statusAfter) `shouldBe` (statusKnowledgeRevision statusBefore, DiscoveryPaused)

  it "ends the owner with a defect when a retry's probe meets a worker failure, never answering it as remaining" $
    withArena $ \probe svc lease → do
      H.addRule probe 1 isRead (H.FailWith (Errno 5))
      failRead svc lease
      H.addRule probe 1 isRead H.Throw
      host ← newHost True
      _ ← okOf (retryWith svc (hostEndpoint svc Nothing host) lease)
      bounded (awaitOwnerStopped svc)
      defects ← inspectDefects svc
      defects `shouldSatisfy` (not . null)
      settledOf host >>= (`shouldSatisfy` \case [Succeeded (ARetried _)] → False; _ → True)

  it "drops a probe whose condition recorded a new failure while it was in flight, and answers on the record as it is then" $
    withTree $ \probe svc lease → do
      pages ← pagesRead probe svc lease (tile 3 4 6)
      (first, lastPage) ← case pages of
        a : rest@(_ : _) → pure (a, last rest)
        _ → expectationFailure ("a read of the column reads fewer than two pages: " <> show pages) >> fail "unreachable"
      H.addRule probe 1 (readAt first) (H.FailWith (Errno 5))
      failRead svc lease
      -- the retry's probe read is held; meanwhile another page fails
      gate ← H.addGateOnce probe isRead
      host ← newHost True
      flip finally (H.openGate gate) $ do
        _ ← okOf (retryWith svc (hostEndpoint svc Nothing host) lease)
        H.awaitReached gate 1
        H.addRule probe (-1) (readAt lastPage) (H.FailWith (Errno 5))
        failRead svc lease
      settled ← waitFor (readTVar (hostSettled host) >>= \s → if null s then retry else pure s)
      case settled of
        [Succeeded (ARetried a)] → (retriedCleared a, retriedRemaining a) `shouldBe` ([], [CondIo])
        other → expectationFailure ("the retry settled " <> show other)
      pausedOn svc lease `shouldReturn` [CondIo]

  describe "a pending extra's one owner" $ do
    it "leaves the store releasing exactly what the backend keeps when a growth cancelled after its allocation fails to give it back, and a retry releases it" $
      withArena $ \probe svc lease → do
        reserved ← H.addGateAfter probe 0 isReserve
        host ← newHost True
        growth ← flip finally (H.openGate reserved) $ do
          growth ← okOf (growWith svc (hostEndpoint svc Nothing host) lease (toInteger (128 * mib)))
          H.awaitReached reserved 1
          cancel svc growth `shouldReturn` CancelWon
          -- the give-back is the next length set: it fails
          H.addRule probe 1 isSetLength (H.FailWith (Errno 5))
          pure growth
        waitFor (backedAtRestSTM svc >>= check)
        pendingExtra ← atomically (inspectPendingExtraSTM svc lease)
        pendingExtra `shouldSatisfy` maybe False (> 0)
        status ← arenaStatus svc lease >>= expectRight
        -- the status counts the pending extra once
        Just (statusPendingReservedBytes status) `shouldBe` pendingExtra
        -- the store knows it is releasing: a retry releases it first
        answer ← retryAnswer svc lease
        answer `shouldSatisfy` either (const False) (const True)
        atomically (inspectPendingExtraSTM svc lease) `shouldReturn` Nothing
        statusPendingReservedBytes <$> (arenaStatus svc lease >>= expectRight) `shouldReturn` 0
        -- and a larger growth goes through
        grown ← growArena svc lease (toInteger (128 * mib)) >>= expectRight >>= bounded . await svc
        fmap grownAllowance grown `shouldBe` Right (128 * mib)
        void (pure growth)
