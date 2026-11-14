-- | The backed terrain service (TRA-22) through its production paths: the owner, the store
-- planner, the storage backend on a real reserved file, and the one publication decision.
--
-- Every race is decided by a gate at the native seam or by a host's eligibility, never by time:
-- a write held at the seam is a write in flight, and the example decides what happens while it
-- is. After each example the service's invariants and its backed oracle ('inspectBacked': pins
-- against gathers, the store's transaction against the slot, the compile account against its
-- holders, the backend's files against the arenas, the edit bank at rest) must be clean.
module Test.TerrainRuntime.Backed.Service (spec) where

import Control.Concurrent.STM
import Control.Exception (finally, try)
import Control.Monad (forM, forM_)
import Hetoimasia.Terrain.Coordinate (decomposeTile, mkLocalCoord)
import Hetoimasia.Terrain.Cell (Cell (..))
import Hetoimasia.Terrain.Residency (ArenaId (..), RegionDemand (..), RegionInfo (..), Revision (..), coverageTile, modelRegions)
import Hetoimasia.Terrain.Runtime
import Hetoimasia.Terrain.Runtime.Settlement
import Hetoimasia.Terrain.Runtime.Store.Admission (Ledger (..))
import qualified Hetoimasia.Terrain.Runtime.Store.Internal.Admission as A
import Hetoimasia.Terrain.Runtime.Store.Internal.Plan (RamCharge (..))
import Hetoimasia.Terrain.Runtime.Storage.Internal.Native (NativeOp (..))
import Hetoimasia.Terrain.Runtime.Storage.Internal.Service (maxRecordControlBytes, resultPageBytes, transferBufferBytes)
import Hetoimasia.Terrain.Runtime.Store.Internal.State (readerRecordBytes)
import Hetoimasia.Terrain.Runtime.Storage.Internal.Types (Errno (..))
import Hetoimasia.Terrain.Runtime.Store (StoreSpec (..), defaultStoreSpec, minAllowanceBytes)
import Test.Hspec
import Test.TerrainRuntime.Fixtures
import qualified Test.TerrainRuntime.Storage.Harness as H

-- | A service whose backend's native calls pass through a harness probe.
withProbedService ∷ Config → (H.Probe → Service → IO a) → IO a
withProbedService config body = do
  probe ← H.newProbe
  withServiceSeam quiet config alwaysAdmitting noProbe (H.seamFor probe) (body probe)

isWrite, isRead, isReserve, isSetLength ∷ NativeOp → Bool
isWrite = \case OpWriteAt {} → True; _ → False
isRead = \case OpReadAt {} → True; _ → False
isReserve = \case OpReserveRange {} → True; _ → False
isSetLength = \case OpSetFileLength {} → True; _ → False

-- | The service is at rest: nothing of the owner's backed work is in flight, and the edit bank
-- holds only the storage service's own records.
atRest ∷ Service → IO ()
atRest svc = waitFor (backedAtRestSTM svc >>= check)

spec ∷ Spec
spec = describe "The backed terrain service" $ do
  it "fits the worst-case transaction beside the full set of reader pins of every arena (the grant never waits for a credit that cannot come)" $ do
    bank ← either (\e → fail (show e)) pure (A.mkEditBankConfig A.defaultEditBankSpec)
    let arenas = [ArenaId n | n ← [0 .. fromInteger (A.ebsArenas A.defaultEditBankSpec) - 1]]
        pins = [cred | aid ← arenas, _ ← [1 .. A.ebsReadersPerArena A.defaultEditBankSpec], cred ← [A.CacheCredit aid A.readerPinnedCacheBytes A.Backed True]]
        pinned = foldr (\c adm → either (error . show) snd (A.reserve A.Foreground [c] adm)) (A.newAdmission bank) pins
    case A.reserve A.Foreground (A.transactionCredits (ArenaId 0) A.worstTransactionCharge) pinned of
      Right _ → pure ()
      Left refusal → expectationFailure ("the worst transaction does not fit beside every reader pin: " <> show refusal)

  it "refuses at construction an edit bank that cannot fund one read beside the worst transaction and every reader pin (a circular wait), and accepts one byte more" $ do
    let atMinimum = toInteger (ramDecodedCopies A.worstTransactionCharge) + 2 * toInteger A.readerPinnedCacheBytes
        spec' cache = A.defaultEditBankSpec {A.ebsCache = cache, A.ebsReadersPerArena = 2}
        config cache = defaultConfig {configMaxArenas = 1, configEditBank = spec' cache}
        need = atMinimum + toInteger resultPageBytes
    -- #662's own minimum (the transaction beside every pin) leaves no room for a read's result
    try (withService (config atMinimum) (\_ → pure ())) >>= \case
      Left (ConfigEditBankReads "cache" needed have) → (needed, have) `shouldBe` (need, atMinimum)
      Left other → expectationFailure ("expected the edit bank refused, got " <> show other)
      Right () → expectationFailure "an edit bank that cannot fund a read was accepted"
    try (withService (config (need - 1)) (\_ → pure ())) >>= \case
      Left (ConfigEditBankReads "cache" _ _) → pure ()
      other → expectationFailure ("expected the edit bank refused one byte short, got " <> either show (const "acceptance") other)
    withService (config need) (\_ → pure ())

  -- The control account must hold, beside the store's own minimum (the worst transaction's control
  -- records, every reader record, the queued descriptors), the storage service's records at their
  -- most (every job record at its largest, one backing record per arena, every kept failure).
  it "accepts the least control account that holds the storage service's records beside the store's minimum, and completes a removal with every arena's backing record held; one byte less is refused at construction" $ do
    let w = A.worstTransactionCharge
        arenas = 2 ∷ Int
        readers = 2 ∷ Integer
        need =
          toInteger (ramPagePins w + ramRootControl w + ramContinuation w)
            + toInteger arenas * readers * toInteger readerRecordBytes
            + toInteger A.maxQueuedDescriptors * toInteger A.descriptorRecordBytes
            + toInteger (maxRecordControlBytes arenas)
        config control = defaultConfig {configMaxArenas = arenas, configEditBank = A.defaultEditBankSpec {A.ebsControl = control, A.ebsReadersPerArena = readers}}
    try (withService (config (need - 1)) (\_ → pure ())) >>= \case
      Left (ConfigEditBankReads "control" needed have) → (needed, have) `shouldBe` (need, need - 1)
      other → expectationFailure ("expected the control account refused one byte short, got " <> either show (const "acceptance") other)
    withService (config need) $ \svc → do
      (client, lease) ← openMain svc "main"
      _ ← okOf (openArena svc client "other" soilOverStone) >>= await svc >>= expectSuccess
      atRest svc
      done ← removeCell' svc lease (tile 3 4 5)
      removeChangedFlag done `shouldBe` True
      settleChecks svc

  it "makes a grant wait for the cache readers' reads hold, and grants it when the reads return (no circular wait)" $ do
    -- the edit bank at the least the service accepts for one arena and two readers: the worst
    -- transaction's decoded copies, two reader pins and one read's result
    let need = toInteger (ramDecodedCopies A.worstTransactionCharge) + 2 * toInteger A.readerPinnedCacheBytes + toInteger resultPageBytes
        bankSpec = A.defaultEditBankSpec {A.ebsCache = need, A.ebsArenas = 1, A.ebsReadersPerArena = 2}
        config = defaultConfig {configMaxArenas = 1, configEditBank = bankSpec}
    granted ← newTVarIO (0 ∷ Int)
    probe ← H.newProbe
    let owner = Probe $ \case
          PointGranted (Just _) _ → atomically (modifyTVar' granted (+ 1))
          _ → pure ()
    withServiceSeam quiet config alwaysAdmitting owner (H.seamFor probe) $ \svc → do
      (_, lease) ← openMain svc "main"
      _ ← removeCell' svc lease (tile 3 4 9)
      -- the removal's discovery is done: nothing internal wants the slot
      waitFor $ arenaStatusSTM svc lease >>= \case
        Right st → check (statusDiscovery st == DiscoveryIdle)
        Left _ → retry
      grantsBefore ← readTVarIO granted
      -- a removal staged and waiting for its host
      host ← newHost False
      _ ← okOf (removeWith svc (hostEndpoint svc Nothing host) lease (tile 3 4 5) Nothing)
      waitFor (readTVar (hostReady host) >>= \n → check (n >= 1))
      -- nothing else holds the slot or a pin (internal work, discovery or reclamation, has finished: it
      -- is offered again only when the committed version moves)
      atRest svc
      -- two reads whose page reads are held at the seam: their pins and their results in flight
      gate ← H.addGate probe isRead
      readers ← flip finally (H.openGate gate) $ do
        readers ← mapM (\at → okOf (cellAt svc lease at)) [tile 8 8 8, tile 9 9 9]
        H.awaitReached gate 2
        -- the removal becomes eligible: the transaction does not fit beside both reads, so its grant waits
        grant host
        -- no transaction staging is reserved: only the two reads' transfer buffers
        bank ← atomically (inspectEditBankSTM svc)
        lgStagingForeground bank `shouldBe` 2 * transferBufferBytes 1
        readTVarIO granted `shouldReturn` grantsBefore
        pure readers
      -- the reads return (the gate opened): their results and pins are released and the grant proceeds
      mapM_ (await svc) readers
      _ ← waitFor (readTVar (hostSettled host) >>= \s' → if null s' then retry else pure s')
      settledOf host >>= (`shouldSatisfy` \case [Succeeded (ARemoved r)] → removeChangedFlag r; _ → False)
      readTVarIO granted >>= (`shouldSatisfy` (> grantsBefore))
      settleChecks svc

  -- A waiting grant is not starved by reads that keep starting: from the grant's refusal (two reads
  -- in flight hold the staging it needs, on the least staging the service's construction check
  -- accepts) to the grant, no new pinned read starts, however many are admitted meanwhile. The arena
  -- may pin three readers and the cache holds all three, so a third read could start: only the rule
  -- that reads yield to a waiting grant keeps it from starting.
  forM_ [5, 20, 60 ∷ Int] $ \arrivals →
   it ("starts no new pinned read between a grant's refusal for want of staging and the grant, however many reads arrive (" <> show arrivals <> ")") $ do
    let w = A.worstTransactionCharge
        staging = toInteger (ramIoBuffers w + ramKeys w + ramScratch w) + toInteger (transferBufferBytes 1)
        config = defaultConfig {configMaxArenas = 1, configEditBank = A.defaultEditBankSpec {A.ebsStaging = staging, A.ebsProtectedStaging = min staging (A.ebsProtectedStaging A.defaultEditBankSpec), A.ebsArenas = 1, A.ebsReadersPerArena = 3}}
    probe ← H.newProbe
    gateRef ← newTVarIO Nothing
    readsAtGrant ← newTVarIO Nothing
    let owner = Probe $ \case
          PointGranted (Just _) _ → atomically $ readTVar gateRef >>= mapM_ (\g → readTVar (H.gReached g) >>= \n → writeTVar readsAtGrant (Just n))
          _ → pure ()
    withServiceSeam quiet config alwaysAdmitting owner (H.seamFor probe) $ \svc → do
      (client, lease) ← openMain svc "main"
      _ ← removeCell' svc lease (tile 3 4 9)
      atRest svc
      edit ← newHost False
      _ ← okOf (removeWith svc (hostEndpoint svc Nothing edit) lease (tile 3 4 5) Nothing)
      waitFor (readTVar (hostReady edit) >>= \n → check (n >= 1))
      atRest svc
      gate ← H.addGate probe isRead
      atomically (writeTVar gateRef (Just gate))
      view ← okOf (openView svc client)
      flip finally (H.openGate gate) $ do
        -- two reads hold their pins and their transfer buffers: the grant will not fit beside them
        _ ← mapM (\at → okOf (cellAt svc lease at)) [tile 8 8 8, tile 9 9 9]
        H.awaitReached gate 2
        grant edit
        -- a stream of reads of the arena, and a load of another of its regions, arrive while it waits
        -- (a third pin and a third transfer buffer are free for them)
        forM_ [1 .. arrivals] $ \k → okOf (cellAt svc lease (tile (fromIntegral k) 12 3))
        let (far, _) = decomposeTile (tile 100 100 0)
        _ ← okOf (setViewDemand svc view lease [RegionDemand far (either (error . show) coverageTile (mkLocalCoord 0 0 0))])
        -- an attach admitted after them is answered (it reads nothing, so it does not wait for the
        -- grant): preparation goes in admission order, so a read that could start has started by now
        other ← okOf (registerClient svc)
        _ ← okOf (attachArena svc other "main") >>= await svc >>= expectSuccess
        -- none of them has started a read: only the two are at the seam
        atomically (readTVar (H.gReached gate)) `shouldReturn` 2
      -- the two reads return, and the grant comes before any new read starts
      _ ← waitFor (readTVar (hostSettled edit) >>= \s' → if null s' then retry else pure s')
      readTVarIO readsAtGrant `shouldReturn` Just 2
      okOf (clearViewDemand svc view)
      closeView svc view
      settleChecks svc

  -- The storage service queues at most eight jobs. With every page read held at the seam, the
  -- removals' reads fill its two workers and its queue; a load demanded meanwhile must not end the
  -- owner: no pinned read starts while the queue is full, and a load whose read is refused for that
  -- pressure keeps its job and reads again. When the reads are let go, everything completes.
  it "keeps a load demanded while the storage queue is full, and completes it once the queue drains" $
    withProbedService defaultConfig $ \probe svc → do
      (client, lease) ← openMain svc "main"
      forM_ [(3, 4, 9), (5, 4, 9)] $ \(x, y, z) → removeCell' svc lease (tile x y z)
      atRest svc
      gate ← H.addGate probe isRead
      view ← okOf (openView svc client)
      hosts ← flip finally (H.openGate gate) $ do
        hosts ← forM [0 .. 13] $ \x → do
          host ← newHost True
          _ ← okOf (removeWith svc (hostEndpoint svc Nothing host) lease (tile x 4 3) Nothing)
          pure host
        -- two reads at the seam and eight in the queue: it is full
        H.awaitReached gate 2
        waitFor (inspectStorageQueuedSTM svc >>= check . (>= 8))
        let (far, _) = decomposeTile (tile 100 100 0)
        _ ← okOf (setViewDemand svc view lease [RegionDemand far (either (error . show) coverageTile (mkLocalCoord 0 0 0))])
        -- an attach admitted after the demand is answered: the owner has acted on it
        other ← okOf (registerClient svc)
        _ ← okOf (attachArena svc other "main") >>= await svc >>= expectSuccess
        inspectDefects svc `shouldReturn` []
        pure hosts
      forM_ hosts $ \h → waitFor (readTVar (hostSettled h) >>= \x → check (not (null x)))
      mapM settledOf hosts >>= (`shouldSatisfy` all (\case [Succeeded (ARemoved r)] → removeChangedFlag r; _ → False))
      -- the demanded region was loaded: a read of it answers
      _ ← readCell svc lease (tile 100 100 0)
      okOf (clearViewDemand svc view)
      closeView svc view
      inspectDefects svc `shouldReturn` []
      settleChecks svc

  it "answers reads of another arena while a removal's write is held, and answers a later read of the removal's arena after it, in admission order" $
    withProbedService defaultConfig $ \probe svc → do
      (client, lease) ← openMain svc "main"
      other ← okOf (openArena svc client "other" soilOverStone) >>= await svc >>= expectSuccess
      _ ← removeCell' svc lease (tile 3 4 9)
      _ ← removeCell' svc other (tile 3 4 9)
      -- nothing else holds the slot: the gate below holds the removal's own write
      atRest svc
      gate ← H.addGate probe isWrite
      remover ← newHost True
      reader ← newHost True
      flip finally (H.openGate gate) $ do
        _ ← okOf (removeWith svc (hostEndpoint svc Nothing remover) lease (tile 3 4 5) Nothing)
        H.awaitReached gate 1
        -- the removal's write is held: reads of the other arena answer, from its committed state
        (cellIs <$> readCell svc other (tile 3 4 9)) `shouldReturn` True
        (cellIs <$> readCell svc other (tile 3 4 5)) `shouldReturn` False
        found ← readCell svc other (tile 8 8 8)
        cellRevision found `shouldBe` Revision 1
        -- a read of the removal's arena admitted after it commits after it (#641's per-arena order)
        _ ← okOf (cellWith svc (hostEndpoint svc Nothing reader) lease (tile 3 4 5))
        readTVarIO (hostSettled remover) `shouldReturn` []
        readTVarIO (hostSettled reader) `shouldReturn` []
      _ ← waitFor (readTVar (hostSettled reader) >>= \s' → if null s' then retry else pure s')
      settledOf remover >>= (`shouldSatisfy` \case [Succeeded (ARemoved r)] → removeChangedFlag r; _ → False)
      -- and sees it
      settledOf reader >>= (`shouldSatisfy` \case [Succeeded (ACell c)] → cellIs c; _ → False)
      settleChecks svc

  -- Of the removal's own arena, what continues while its write is outstanding: a borrowed snapshot stays
  -- readable (the committed state it was taken at), and a load of another of its regions (a view's
  -- demand) reads the store and becomes resident. Its data requests admitted after the removal wait for
  -- it, in admission order (the example above).
  it "keeps a borrowed snapshot readable and completes a load of the same arena while a removal's write is held" $
    withProbedService defaultConfig $ \probe svc → do
      (client, lease) ← openMain svc "main"
      _ ← removeCell' svc lease (tile 3 4 9)
      _ ← readCell svc lease (tile 3 4 5)
      atRest svc
      let (held, _) = decomposeTile (tile 3 4 5)
          (far, _) = decomposeTile (tile 40 40 0)
      view ← okOf (openView svc client)
      gate ← H.addGate probe isWrite
      remover ← newHost True
      outcome ← flip finally (H.openGate gate) $ withSnapshot svc lease [held] $ \snapshot → do
        _ ← okOf (removeWith svc (hostEndpoint svc Nothing remover) lease (tile 3 4 5) Nothing)
        H.awaitReached gate 1
        -- the removal's write is held at the seam
        _ ← okOf (setViewDemand svc view lease [RegionDemand far (either (error . show) coverageTile (mkLocalCoord 0 0 0))])
        waitFor $ inspectModelSTM svc >>= \m → check (far `elem` map regionCoord (modelRegions m))
        -- the snapshot reads the committed state: the earlier removal is air, the held one still solid
        snapshotCell snapshot (tile 3 4 9) `shouldSatisfy` \case Known c → c == Air; _ → False
        snapshotCell snapshot (tile 3 4 5) `shouldSatisfy` \case Known c → c /= Air; _ → False
        readTVarIO (hostSettled remover) `shouldReturn` []
      either (\r → expectationFailure (show r)) pure outcome
      _ ← waitFor (readTVar (hostSettled remover) >>= \s' → if null s' then retry else pure s')
      settledOf remover >>= (`shouldSatisfy` \case [Succeeded (ARemoved r)] → removeChangedFlag r; _ → False)
      okOf (clearViewDemand svc view)
      closeView svc view
      settleChecks svc

  it "keeps a read pending while its authoritative page is delayed, and answers it from the store, never from the source" $
    withProbedService defaultConfig $ \probe svc → do
      (_, lease) ← openMain svc "main"
      _ ← removeCell' svc lease (tile 3 4 9)
      atRest svc
      gate ← H.addGate probe isRead
      host ← newHost True
      flip finally (H.openGate gate) $ do
        _ ← okOf (cellWith svc (hostEndpoint svc Nothing host) lease (tile 3 4 9))
        H.awaitReached gate 1
        -- the page is delayed: nothing is answered (the source would say solid; the store says air)
        readTVarIO (hostSettled host) `shouldReturn` []
      _ ← waitFor (readTVar (hostSettled host) >>= \s' → if null s' then retry else pure s')
      settledOf host >>= (`shouldSatisfy` \case [Succeeded (ACell found)] → cellIs found; _ → False)
      settleChecks svc

  it "refuses a removal that could need the last value of a revision before any work, and stops internal work whose next commit would wrap, with no defect and nothing wrapped" $
    withService defaultConfig {configFirstRevision = maxBound - 2} $ \svc → do
      (_, lease) ← openMain svc "main"
      first ← removeCell' svc lease (tile 3 4 5)
      (removeChangedFlag first, removeRevision first) `shouldBe` (True, Revision (maxBound - 1))
      -- the content revision could reach its last value: refused before admission, nothing created
      removeAt svc lease (tile 3 4 6) Nothing >>= \r → refusedWith r `shouldBe` Just RefusedExhausted
      -- the removal's obligation is worked until the store's version would wrap; then internal work
      -- stops, the arena's committed state stands, and nothing is a defect
      waitFor $ arenaStatusSTM svc lease >>= \case
        Right st → check (statusDiscovery st /= DiscoveryIdle)
        Left _ → retry
      status ← arenaStatus svc lease >>= expectRight
      statusContentRevision status `shouldBe` Revision (maxBound - 1)
      found ← readCell svc lease (tile 3 4 5)
      (cellIs found, cellRevision found) `shouldBe` (True, Revision (maxBound - 1))
      settleChecks svc

  it "settles an open on an unqualified filesystem as storage_unsupported, publishes nothing, releases the name and leaves no file" $
    withProbedService defaultConfig $ \probe svc → do
      H.addRule probe (-1) (\case OpStatFilesystem → True; _ → False) (H.FilesystemIs "tmpfs")
      client ← okOf (registerClient svc)
      outcome ← okOf (openArena svc client "main" soilOverStone) >>= await svc
      outcome `shouldSatisfy` \case Left (Failed (StorageFailed (FaultUnsupported _))) → True; _ → False
      atRest svc
      settleChecks svc

  it "settles an open whose reservation fails as reservation_failed, publishes nothing and lets the name be opened again" $
    withProbedService defaultConfig $ \probe svc → do
      H.addRule probe 1 isReserve (H.FailWith (Errno 28))
      client ← okOf (registerClient svc)
      outcome ← okOf (openArena svc client "main" soilOverStone) >>= await svc
      outcome `shouldSatisfy` \case Left (Failed (StorageFailed (FaultReservation _))) → True; _ → False
      -- the name is free again, and the next open (the rule is spent) reserves and publishes
      lease ← okOf (openArena svc client "main" soilOverStone) >>= await svc >>= expectSuccess
      _ ← readCell svc lease (tile 0 0 0)
      atRest svc
      settleChecks svc

  it "writes a removal to the arena's file before it publishes it, and reads it back from the store" $
    withProbedService defaultConfig $ \probe svc → do
      (_, lease) ← openMain svc "main"
      answer ← removeCell' svc lease (tile 3 4 5)
      (removeChangedFlag answer, removeRevision answer) `shouldBe` (True, Revision 1)
      writes ← atomically (H.countEvents probe isWrite)
      writes `shouldSatisfy` (> 0)
      found ← readCell svc lease (tile 3 4 5)
      (cellIs found, cellRevision found) `shouldBe` (True, Revision 1)
      view ← inspectArena svc lease >>= maybe (fail "arena vanished") pure
      -- the content revision is the removal's; the store revision counts every commit (its discovery batches too)
      viewRevision view `shouldBe` Revision 1
      viewStoreRevision view `shouldSatisfy` (>= Revision 1)
      atRest svc
      settleChecks svc

  it "lets a cancellation win while the writes are held, keeps the old root, and retires the claims only after the write returns" $
    withProbedService defaultConfig $ \probe svc → do
      (_, lease) ← openMain svc "main"
      gate ← H.addGate probe isWrite
      host ← newHost True
      request ← okOf (removeWith svc (hostEndpoint svc Nothing host) lease (tile 3 4 5) Nothing)
      H.awaitReached gate 1
      cancel svc request `shouldReturn` CancelWon
      settledOf host `shouldReturn` [Cancelled]
      found ← readCell svc lease (tile 3 4 5)
      (cellIs found, cellRevision found) `shouldBe` (False, Revision 0)
      H.openGate gate
      atRest svc
      cancel svc request `shouldReturn` AlreadySettled
      settleChecks svc

  it "makes a later cancellation answer that the request was settled once the decision committed it" $
    withProbedService defaultConfig $ \_ svc → do
      (_, lease) ← openMain svc "main"
      host ← newHost True
      request ← okOf (removeWith svc (hostEndpoint svc Nothing host) lease (tile 3 4 5) Nothing)
      _ ← waitFor (readTVar (hostSettled host) >>= \s → if null s then retry else pure s)
      cancel svc request `shouldReturn` AlreadySettled
      settledOf host `shouldReturn` [Succeeded (ARemoved (RemoveAnswer (ArenaId 0) (Revision 1) True))]
      settleChecks svc

  it "pauses the arena with storage_io when a write fails, settles the removal with it, keeps the old terrain readable and settles a new removal at once" $
    withProbedService defaultConfig $ \probe svc → do
      (_, lease) ← openMain svc "main"
      H.addRule probe (-1) isWrite (H.FailWith (Errno 5))
      first ← removeAt svc lease (tile 3 4 5) Nothing >>= expectRight >>= await svc
      first `shouldSatisfy` \case Left (Failed (StorageFailed (FaultIo _))) → True; _ → False
      found ← readCell svc lease (tile 3 4 5)
      (cellIs found, cellRevision found) `shouldBe` (False, Revision 0)
      view ← inspectArena svc lease >>= maybe (fail "arena vanished") pure
      viewPaused view `shouldBe` [CondIo]
      second ← removeAt svc lease (tile 6 6 6) Nothing >>= expectRight >>= await svc
      second `shouldSatisfy` \case Left (Failed (StorageFailed (FaultIo _))) → True; _ → False
      status ← arenaStatus svc lease >>= expectRight
      statusStorage status `shouldBe` StoragePaused [CondIo]
      atRest svc
      settleChecks svc

  it "keeps more than four accepted removals waiting with no transaction credit, then commits them all" $
    withProbedService defaultConfig $ \_ svc → do
      (_, lease) ← openMain svc "main"
      atRest svc
      -- what the bank holds at rest: the storage service's record of the arena's backing
      rest ← atomically (inspectEditBankSTM svc)
      hosts ← forM [0 .. 5 ∷ Integer] $ \x → do
        host ← newHost False
        _ ← okOf (removeWith svc (hostEndpoint svc Nothing host) lease (tile x 0 3) Nothing)
        pure host
      -- every removal is staged and waits for its host; none holds the transaction's RAM
      forM_ hosts $ \host → waitFor (readTVar (hostReady host) >>= \n → check (n >= 1))
      bank ← atomically (inspectEditBankSTM svc)
      (lgStagingForeground bank, lgControlReserved bank) `shouldBe` (0, lgControlReserved rest)
      forM_ hosts grant
      forM_ hosts $ \host → waitFor (readTVar (hostSettled host) >>= \s → check (not (null s)))
      results ← mapM settledOf hosts
      [r | [Succeeded (ARemoved r)] ← results] `shouldSatisfy` ((== 6) . length)
      atRest svc
      settleChecks svc

  it "grows the allowance: equal succeeds unchanged, smaller is storage_size_not_increased, larger commits with the cap" $
    withProbedService defaultConfig $ \_ svc → do
      (_, lease) ← openMain svc "main"
      let mib = 1024 * 1024 ∷ Integer
      equal ← growArena svc lease (toInteger minAllowanceBytes) >>= expectRight >>= await svc
      fmap grownChanged equal `shouldBe` Right False
      larger ← growArena svc lease (128 * mib) >>= expectRight >>= await svc
      fmap (\a → (grownAllowance a, grownChanged a)) larger `shouldBe` Right (fromInteger (128 * mib), True)
      smaller ← growArena svc lease (64 * mib) >>= expectRight >>= await svc
      smaller `shouldSatisfy` \case Left (Failed (StorageFailed (FaultSizeNotIncreased _ _))) → True; _ → False
      status ← arenaStatus svc lease >>= expectRight
      (statusReservedBytes status, statusPendingReservedBytes status) `shouldBe` (128 * fromIntegral mib, 0)
      atRest svc
      settleChecks svc

  it "settles a growth whose reservation is refused as reservation_failed, keeps the old cap, and grows on a later request" $
    withProbedService defaultConfig $ \probe svc → do
      (_, lease) ← openMain svc "main"
      let mib = 1024 * 1024 ∷ Integer
      H.addRule probe 1 isReserve (H.FailWith (Errno 28))
      failed ← growArena svc lease (128 * mib) >>= expectRight >>= await svc
      failed `shouldSatisfy` \case Left (Failed (StorageFailed (FaultReservation _))) → True; _ → False
      kept ← arenaStatus svc lease >>= expectRight
      (statusReservedBytes kept, statusPendingReservedBytes kept) `shouldBe` (minAllowanceBytes, 0)
      atRest svc
      grown ← growArena svc lease (128 * mib) >>= expectRight >>= await svc
      fmap grownAllowance grown `shouldBe` Right (fromInteger (128 * mib))
      settleChecks svc

  it "cancels a growth while its reservation is held: it settles once, and the reservation's extra is given back when it returns" $
    withProbedService defaultConfig $ \probe svc → do
      (_, lease) ← openMain svc "main"
      gate ← H.addGate probe isReserve
      host ← newHost True
      flip finally (H.openGate gate) $ do
        request ← okOf (growWith svc (hostEndpoint svc Nothing host) lease (128 * 1024 * 1024))
        H.awaitReached gate 1
        cancel svc request `shouldReturn` CancelWon
      _ ← waitFor (readTVar (hostSettled host) >>= \s' → if null s' then retry else pure s')
      settledOf host `shouldReturn` [Cancelled]
      atRest svc
      status ← arenaStatus svc lease >>= expectRight
      (statusReservedBytes status, statusPendingReservedBytes status) `shouldBe` (minAllowanceBytes, 0)
      settleChecks svc

  it "keeps an obtained extra pending, charged and visible when giving it back fails, and releases it before the growth goes on" $
    withProbedService defaultConfig $ \probe svc → do
      (_, lease) ← openMain svc "main"
      let mib = 1024 * 1024 ∷ Integer
      gate ← H.addGate probe isReserve
      host ← newHost True
      flip finally (H.openGate gate) $ do
        _ ← okOf (growWith svc (hostEndpoint svc Nothing host) lease (128 * mib))
        H.awaitReached gate 1
        -- the host is no longer eligible when the decision comes: the obtained extra is given back,
        -- and giving it back fails (the growth's own length is set first, then the release's)
        atomically (writeTVar (hostEligible host) False)
        H.addRuleAfter probe 1 1 isSetLength (H.FailWith (Errno 5))
      waitFor $ arenaStatusSTM svc lease >>= \case
        Right st → check (statusPendingReservedBytes st > 0)
        Left _ → retry
      held ← arenaStatus svc lease >>= expectRight
      statusReservedBytes held `shouldBe` minAllowanceBytes
      -- the host is eligible again: the growth contends again, releases the pending extra first, and grows
      grant host
      _ ← waitFor (readTVar (hostSettled host) >>= \s' → if null s' then retry else pure s')
      settledOf host >>= (`shouldSatisfy` \case [Succeeded (AGrown a)] → grownAllowance a == fromInteger (128 * mib); _ → False)
      grownStatus ← arenaStatus svc lease >>= expectRight
      (statusReservedBytes grownStatus, statusPendingReservedBytes grownStatus) `shouldBe` (fromInteger (128 * mib), 0)
      atRest svc
      settleChecks svc

  it "releases a pending extra on an explicit retry, under the slot, and answers it" $
    withProbedService defaultConfig $ \probe svc → do
      (_, lease) ← openMain svc "main"
      gate ← H.addGate probe isReserve
      host ← newHost True
      growth ← flip finally (H.openGate gate) $ do
        growth ← okOf (growWith svc (hostEndpoint svc Nothing host) lease (128 * 1024 * 1024))
        H.awaitReached gate 1
        atomically (writeTVar (hostEligible host) False)
        H.addRuleAfter probe 1 1 isSetLength (H.FailWith (Errno 5))
        pure growth
      waitFor $ arenaStatusSTM svc lease >>= \case
        Right st → check (statusPendingReservedBytes st > 0)
        Left _ → retry
      -- the growth's slot work has ended (its extra was given back and that failed): only then is the extra
      -- pending for a retry to release (while the growth still holds it, it is reported pending too)
      atRest svc
      retried ← retryArena svc lease >>= expectRight >>= await svc
      fmap retriedRemaining retried `shouldBe` Right []
      status ← arenaStatus svc lease >>= expectRight
      (statusReservedBytes status, statusPendingReservedBytes status) `shouldBe` (minAllowanceBytes, 0)
      cancel svc growth `shouldReturn` CancelWon
      atRest svc
      settleChecks svc

  it "answers a retry of a ready arena idempotently, and refuses growth and retry to an attached lease" $
    withProbedService defaultConfig $ \_ svc → do
      (_, lease) ← openMain svc "main"
      retried ← retryArena svc lease >>= expectRight >>= await svc
      fmap (\a → (retriedCleared a, retriedRemaining a)) retried `shouldBe` Right ([], [])
      other ← okOf (registerClient svc)
      attached ← okOf (attachArena svc other "main") >>= await svc >>= expectSuccess
      growArena svc attached (128 * 1024 * 1024) >>= \r → refusedWith r `shouldBe` Just RefusedAuthority
      retryArena svc attached >>= \r → refusedWith r `shouldBe` Just RefusedAuthority
      settleChecks svc

  it "closes an arena while its write is held: the request ends once, the write drains, then the file closes" $
    withProbedService defaultConfig $ \probe svc → do
      (client, lease) ← openMain svc "main"
      gate ← H.addGate probe isWrite
      host ← newHost True
      -- the gate is opened whatever happens: a held write would otherwise keep the service's drain waiting
      flip finally (H.openGate gate) $ do
        _ ← okOf (removeWith svc (hostEndpoint svc Nothing host) lease (tile 3 4 5) Nothing)
        H.awaitReached gate 1
        endClient svc client
        -- the close settles the removal once (the owner does it on its next step), with the write still held:
        -- as the arena's closure or as a cancellation of its in-flight transaction (the sweep's outcomes)
        _ ← waitFor (readTVar (hostSettled host) >>= \s' → if null s' then retry else pure s')
        settledOf host >>= (`shouldSatisfy` (`elem` [[Failed ArenaClosed], [Cancelled]]))
      atRest svc
      inspectBacked svc >>= (`shouldBe` [])
      settleChecks svc

  it "opens an arena of a configured larger allowance and reserves it" $
    withProbedService defaultConfig {configStore = defaultStoreSpec {specAllowanceBytes = 2 * toInteger minAllowanceBytes}} $ \_ svc → do
      (_, lease) ← openMain svc "main"
      status ← arenaStatus svc lease >>= expectRight
      statusReservedBytes status `shouldBe` 2 * minAllowanceBytes
      settleChecks svc
