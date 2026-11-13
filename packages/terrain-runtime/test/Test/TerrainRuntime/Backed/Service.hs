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
import Hetoimasia.Terrain.Residency (ArenaId (..), Revision (..))
import Hetoimasia.Terrain.Runtime
import Hetoimasia.Terrain.Runtime.Settlement
import Hetoimasia.Terrain.Runtime.Store.Admission (Ledger (..))
import qualified Hetoimasia.Terrain.Runtime.Store.Internal.Admission as A
import Hetoimasia.Terrain.Runtime.Store.Internal.Plan (RamCharge (..))
import Hetoimasia.Terrain.Runtime.Storage.Internal.Native (NativeOp (..))
import Hetoimasia.Terrain.Runtime.Storage.Internal.Service (resultPageBytes)
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
        bank ← atomically (inspectEditBankSTM svc)
        lgStagingForeground bank `shouldBe` 0
        readTVarIO granted `shouldReturn` grantsBefore
        pure readers
      -- the reads return (the gate opened): their results and pins are released and the grant proceeds
      mapM_ (await svc) readers
      _ ← waitFor (readTVar (hostSettled host) >>= \s' → if null s' then retry else pure s')
      settledOf host >>= (`shouldSatisfy` \case [Succeeded (ARemoved r)] → removeChangedFlag r; _ → False)
      readTVarIO granted >>= (`shouldSatisfy` (> grantsBefore))
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
