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
import Control.Exception (finally)
import Control.Monad (forM_, void, when)
import Data.Word (Word64)
import qualified Hetoimasia.Terrain.Connectivity as C
import Hetoimasia.Terrain.Source (defaultSourceLimits, mkSource)
import Hetoimasia.Terrain.Runtime
import Hetoimasia.Terrain.Runtime.Settlement
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

-- | The edit bank holds nothing of the owner's (no pin, no transaction, no staging): only the
-- storage service's own records, with no task of the owner and no job of the backend.
bankAtRest ∷ Service → IO ()
bankAtRest svc = waitFor (backedAtRestSTM svc >>= check)

oracle ∷ Service → IO ()
oracle svc = do
  inspectInvariants svc >>= (`shouldBe` [])
  inspectBacked svc >>= (`shouldBe` [])

spec ∷ Spec
spec = do
  describe "The backed removal's ending paths (sweep)" $
    forM_ [minBound .. maxBound] $ \step → forM_ [minBound .. maxBound] $ \exit →
      it ("held " <> show step <> ", ended " <> show exit) (sweepCase step exit)
  describe "The backed removal's staged write prefixes (sweep)" $
    it "fails each page write of a removal's transaction in turn: the arena pauses with storage_io, its committed terrain stays readable, nothing more is written, and the abort drains" $ do
      -- how many pages the transaction writes, counted on an uninterrupted run
      writes ← do
        probe ← H.newProbe
        withServiceSeam quiet defaultConfig alwaysAdmitting noProbe (H.seamFor probe) $ \svc → do
          (_, lease) ← openMain svc "main"
          _ ← removeCell' svc lease (tile 3 4 9)
          bankAtRest svc
          writesBefore ← atomically (H.countEvents probe isWrite)
          _ ← removeCell' svc lease (tile 3 4 5)
          bankAtRest svc
          after' ← atomically (H.countEvents probe isWrite)
          pure (after' - writesBefore)
      writes `shouldSatisfy` (>= 1)
      forM_ [1 .. writes] $ \k → do
        probe ← H.newProbe
        withServiceSeam quiet defaultConfig alwaysAdmitting noProbe (H.seamFor probe) $ \svc → do
          (_, lease) ← openMain svc "main"
          _ ← removeCell' svc lease (tile 3 4 9)
          bankAtRest svc
          -- the k-th page write fails: the first k - 1 were written, the rest never are
          H.addRuleAfter probe (k - 1) 1 isWrite (H.FailWith (Errno 5))
          writesBefore ← atomically (H.countEvents probe isWrite)
          failed ← removeAt svc lease (tile 3 4 5) Nothing >>= expectRight >>= await svc
          (k, failed) `shouldSatisfy` \case (_, Left (Failed (StorageFailed (FaultIo _)))) → True; _ → False
          bankAtRest svc
          oracle svc
          after' ← atomically (H.countEvents probe isWrite)
          (k, after' - writesBefore) `shouldBe` (k, k)
          -- the committed terrain: the earlier removal is air, the failed one's cell is still solid
          (cellIs <$> readCell svc lease (tile 3 4 9)) `shouldReturn` True
          (cellIs <$> readCell svc lease (tile 3 4 5)) `shouldReturn` False
          status ← arenaStatus svc lease >>= expectRight
          statusStorage status `shouldBe` StoragePaused [CondIo]
  describe "The backed open's ending paths (sweep)" $
    forM_ [minBound .. maxBound] $ \step → forM_ [e | e ← [minBound .. maxBound], applies step e] $ \exit →
      it ("held " <> show step <> ", ended " <> show exit) (openCase step exit)
  where
    -- nothing native runs while an open compiles or waits for its host: a native failure is the
    -- reserving step's
    applies OpenCompiling OpenByNativeFailure = False
    applies OpenDelayed OpenByNativeFailure = False
    applies _ _ = True

-- | Where an open is held: its compilation charged and about to run (the owner held at
-- 'PointCompiling'), its file's reservation in flight (held at the native seam), or prepared
-- completely (compiled, its file reserved, its initial store made) and waiting for its host's
-- eligibility to be published (the delayed logical open).
data OpenStep = OpenCompiling | OpenReserving | OpenDelayed
  deriving stock (Eq, Show, Enum, Bounded)

data OpenExit = OpenByCancel | OpenByClientEnd | OpenByServiceClose | OpenByNativeFailure | OpenByComplete
  deriving stock (Eq, Show, Enum, Bounded)

isReserve ∷ NativeOp → Bool
isReserve = \case OpReserveRange {} → True; _ → False

-- | An open held at a step and ended by an exit: it settles once, nothing of it is left (no
-- compile charge, no file, no bank credit: the oracle and the bank at rest), and unless the service
-- closed, the name can be opened again.
openCase ∷ OpenStep → OpenExit → IO ()
openCase step exit = do
  probe ← H.newProbe
  reached ← newEmptyTMVarIO
  release ← newEmptyTMVarIO
  let owner = Probe $ \case
        -- the first compilation is held (until the exit is made); a later one (the name opened again) is not
        PointCompiling _ | step == OpenCompiling → do
          first ← atomically (tryPutTMVar reached ())
          when first (atomically (readTMVar release))
        _ → pure ()
  withServiceSeam quiet defaultConfig alwaysAdmitting owner (H.seamFor probe) $ \svc → do
    client ← okOf (registerClient svc)
    gate ← case (step, exit) of
      (OpenReserving, OpenByNativeFailure) → H.addRule probe 1 isReserve (H.FailWith (Errno 28)) >> pure Nothing
      (OpenReserving, _) → Just <$> H.addGate probe isReserve
      (OpenCompiling, _) → pure Nothing
      (OpenDelayed, _) → pure Nothing
    let unhold = atomically (void (tryPutTMVar release ())) >> forM_ gate H.openGate
    host ← newHost (step /= OpenDelayed)
    flip finally unhold $ do
      request ← okOf (openArenaWith svc (hostEndpoint svc Nothing host) client "main" soilOverStone)
      -- reach the step
      case (step, gate) of
        (OpenCompiling, _) → waitFor (readTMVar reached)
        (OpenDelayed, _) → waitFor (readTVar (hostReady host) >>= \n → check (n >= 1))
        (_, Just g) → H.awaitReached g 1
        (_, Nothing) → pure ()
      -- the exit
      case exit of
        OpenByCancel → cancel svc request `shouldReturn` CancelWon
        OpenByClientEnd → endClient svc client
        OpenByServiceClose → closeService svc
        OpenByNativeFailure → pure ()
        OpenByComplete → when (step == OpenDelayed) (grant host)
      unhold
      settled ← waitFor (readTVar (hostSettled host) >>= \s' → if null s' then retry else pure s')
      -- it settles once
      length settled `shouldBe` 1
      case exit of
        OpenByComplete → settled `shouldSatisfy` \case [Succeeded (AOpened _)] → True; _ → False
        OpenByNativeFailure → settled `shouldSatisfy` \case [Failed (StorageFailed (FaultReservation _))] → True; _ → False
        OpenByCancel → settled `shouldBe` [Cancelled]
        _ → settled `shouldSatisfy` \case [Succeeded _] → False; _ → True
    bankAtRest svc
    oracle svc
    atomically (inspectCompileSTM svc) >>= \(use, _) → use `shouldBe` (if exit == OpenByComplete then perArenaUse else 0)
    -- the name is free again (or still the completed arena's: a second open of it is refused)
    when (exit `notElem` [OpenByClientEnd, OpenByServiceClose, OpenByComplete]) $ do
      lease ← okOf (openArena svc client "main" soilOverStone) >>= await svc >>= expectSuccess
      _ ← readCell svc lease (tile 0 0 0)
      pure ()
  where
    perArenaUse = fixtureShare

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

-- | What the fixture arena keeps of the compile account: its compiled connectivity and member index.
fixtureShare ∷ Word64
fixtureShare = case mkSource defaultSourceLimits soilOverStone of
  Left e → error ("the fixture source was refused: " <> show e)
  Right src → either (error . show) (\(_, st) → fromInteger (C.workResultBytes st + 32 * C.workNodes st)) (C.prepareConnectivity C.defaultConnectivityLimits src)
