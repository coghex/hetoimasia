-- | The creator's commands (growth and retry) against whatever growth of the same arena is in
-- flight when they arrive. A creator command is prepared against the arena's allowance and growth
-- state; it is not prepared while the slot runs a growth or a pending extra's release of that
-- arena, and what it staged goes stale (and is prepared again) when either moves before its grant.
--
-- Every example starts from an arena already grown to 128 MiB, so that a smaller size is still a
-- valid one. A first growth F asks for 192 MiB; the command C under test arrives while F is in
-- one of five states, decided by gates at the native seam and by F's host's eligibility, never by
-- time. C is "equal", "larger" (64 MiB more) or "smaller" (32 MiB less) than the allowance it is
-- answered against, or a retry.
module Test.TerrainRuntime.Backed.Creator (spec) where

import Control.Concurrent.STM
import Control.Exception (finally)
import Control.Monad (forM_, when)
import Data.Word (Word64)
import Hetoimasia.Terrain.Runtime
import Hetoimasia.Terrain.Runtime.Settlement
import Hetoimasia.Terrain.Runtime.Storage.Internal.Native (NativeOp (..))
import Hetoimasia.Terrain.Runtime.Storage.Internal.Types (Errno (..))
import Test.Hspec
import Test.TerrainRuntime.Fixtures
import qualified Test.TerrainRuntime.Storage.Harness as H

data InFlight
  = -- | nothing of the arena's growth is in flight
    Nothing'
  | -- | F is staged, its host not yet eligible; C completes first, then F is granted
    Staged'
  | -- | F holds the slot, its reservation held at the seam
    Reserving
  | -- | F holds the slot and is giving its extra back (its host withdrew); the release is held at
    -- the seam and then fails, leaving the extra pending
    Abandoning
  | -- | F's run has ended with its extra pending
    PendingExtra
  deriving stock (Eq, Show, Enum, Bounded)

data Command = GrowEqual | GrowLarger | GrowSmaller | Retry
  deriving stock (Eq, Show, Enum, Bounded)

mib ∷ Word64
mib = 1024 * 1024

isReserve, isSetLength ∷ NativeOp → Bool
isReserve = \case OpReserveRange {} → True; _ → False
isSetLength = \case OpSetFileLength {} → True; _ → False

-- | The allowance C is answered against, and whether an extra is pending then.
basis ∷ InFlight → (Word64, Bool)
basis = \case
  Nothing' → (128 * mib, False)
  Staged' → (128 * mib, False)
  Reserving → (192 * mib, False)
  Abandoning → (128 * mib, True)
  PendingExtra → (128 * mib, True)

spec ∷ Spec
spec = describe "The creator's commands against an arena's growth in flight" $
  forM_ [minBound .. maxBound] $ \inFlight →
    forM_ [minBound .. maxBound] $ \command →
      it (show command <> " while " <> show inFlight) (creatorCase inFlight command)

creatorCase ∷ InFlight → Command → IO ()
creatorCase inFlight command = do
  probe ← H.newProbe
  withServiceSeam quiet defaultConfig alwaysAdmitting noProbe (H.seamFor probe) $ \svc → do
    (_, lease) ← openMain svc "main"
    (_, otherLease) ← openMain svc "other"
    first ← growArena svc lease (toInteger (128 * mib)) >>= expectRight >>= await svc
    fmap grownAllowance first `shouldBe` Right (128 * mib)
    waitFor (backedAtRestSTM svc >>= check)
    let (base, extraPending) = basis inFlight
        target = case command of
          GrowEqual → Just base
          GrowLarger → Just (base + 64 * mib)
          GrowSmaller → Just (base - 32 * mib)
          Retry → Nothing
    fHost ← newHost (inFlight /= Staged')
    cHost ← newHost True
    let submitF = okOf (growWith svc (hostEndpoint svc Nothing fHost) lease (toInteger (192 * mib)))
        submitC = case target of
          Just bytes → okOf (growWith svc (hostEndpoint svc Nothing cHost) lease (toInteger bytes))
          Nothing → okOf (retryWith svc (hostEndpoint svc Nothing cHost) lease)
        -- while F holds the slot: a read of another arena admitted after C is answered, and C has
        -- not been prepared (preparation and commits go in admission order, so C would have been
        -- prepared, and a retry answered, before it)
        notPreparedWhileHeld = do
          _ ← readCell svc otherLease (tile 0 0 0)
          readTVarIO (hostReady cHost) `shouldReturn` 0
          readTVarIO (hostSettled cHost) `shouldReturn` []
        settled host = waitFor (readTVar (hostSettled host) >>= \s → if null s then retry else pure s)
    fRequest ← case inFlight of
      Nothing' → pure Nothing
      Staged' → do
        f ← submitF
        -- F is staged against 128 MiB and waits for its host
        waitFor (readTVar (hostReady fHost) >>= \n → check (n >= 1))
        _ ← submitC
        _ ← settled cHost
        grant fHost
        pure (Just f)
      Reserving → do
        gate ← H.addGateOnce probe isReserve
        f ← flip finally (H.openGate gate) $ do
          f ← submitF
          H.awaitReached gate 1
          _ ← submitC
          notPreparedWhileHeld
          pure f
        pure (Just f)
      Abandoning → do
        reserve ← H.addGateOnce probe isReserve
        -- the growth's own length is set first, then the release's: hold and fail the release's
        release ← H.addGateAfter probe 1 isSetLength
        H.addRuleAfter probe 1 1 isSetLength (H.FailWith (Errno 5))
        flip finally (H.openGate reserve >> H.openGate release) $ do
          f ← submitF
          H.awaitReached reserve 1
          atomically (writeTVar (hostEligible fHost) False)
          H.openGate reserve
          H.awaitReached release 1
          -- F's run is giving its extra back, in the slot: C arrives now
          _ ← submitC
          notPreparedWhileHeld
          pure (Just f)
      PendingExtra → do
        reserve ← H.addGateOnce probe isReserve
        H.addRuleAfter probe 1 1 isSetLength (H.FailWith (Errno 5))
        f ← flip finally (H.openGate reserve) $ do
          f ← submitF
          H.awaitReached reserve 1
          atomically (writeTVar (hostEligible fHost) False)
          pure f
        -- F's run has ended: its extra is pending, and nothing is in the slot
        waitFor (arenaStatusSTM svc lease >>= either (const retry) (check . (> 0) . statusPendingReservedBytes))
        waitFor (backedAtRestSTM svc >>= check)
        _ ← submitC
        pure (Just f)
    when (inFlight == Nothing') (() <$ submitC)
    outcome ← settled cHost
    status ← waitFor (arenaStatusSTM svc lease >>= either (const retry) pure)
    let reserved = statusReservedBytes status
        pendingNow = statusPendingReservedBytes status
    case (command, outcome) of
      (GrowEqual, [Succeeded (AGrown a)]) → do
        (grownAllowance a, grownChanged a) `shouldBe` (base, False)
        (pendingNow > 0) `shouldBe` extraPending
      (GrowLarger, [Succeeded (AGrown a)]) → do
        (grownAllowance a, grownChanged a) `shouldBe` (base + 64 * mib, True)
        pendingNow `shouldBe` 0
      (GrowSmaller, [Failed (StorageFailed (FaultSizeNotIncreased from to))]) → do
        (from, to) `shouldBe` (base, base - 32 * mib)
        (pendingNow > 0) `shouldBe` extraPending
      (Retry, [Succeeded (ARetried a)]) → do
        retriedRemaining a `shouldBe` []
        -- a pending extra is released by the retry, under the slot
        pendingNow `shouldBe` 0
      _ → expectationFailure ("C settled " <> show outcome)
    -- F's own outcome
    case inFlight of
      Staged' → do
        fOutcome ← settled fHost
        let afterC = case command of GrowLarger → base + 64 * mib; GrowEqual → base; _ → base
        case fOutcome of
          [Succeeded (AGrown a)] → (grownAllowance a, grownChanged a) `shouldBe` (max afterC (192 * mib), afterC < 192 * mib)
          other → expectationFailure ("F settled " <> show other)
      Reserving → settled fHost >>= (`shouldSatisfy` \case [Succeeded (AGrown a)] → grownAllowance a == 192 * mib; _ → False)
      _ → pure ()
    -- whatever is left pending is released, and F (still waiting for its host) is cancelled
    when (pendingNow > 0) $ do
      released ← retryArena svc lease >>= expectRight >>= await svc
      fmap retriedRemaining released `shouldBe` Right []
    forM_ fRequest $ \f → when (inFlight `elem` [Abandoning, PendingExtra]) (cancel svc f `shouldReturn` CancelWon)
    final ← waitFor (arenaStatusSTM svc lease >>= either (const retry) pure)
    statusPendingReservedBytes final `shouldBe` 0
    (statusReservedBytes final >= reserved) `shouldBe` True
    waitFor (backedAtRestSTM svc >>= check)
    settleChecks svc
