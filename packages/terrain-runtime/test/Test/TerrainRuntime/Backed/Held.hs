-- | Held closes take the control account's room for good: a close that raises is held on every
-- platform (it is not established to have released the descriptor), and its record lives to the
-- service's end. Nothing bounds how many there are, so when they have taken the room the owner must
-- end loudly, never wait: a recorded defect that names them, and every request settled by the
-- owner's end.
--
-- On the least control account the service accepts (two arenas of two readers), an arena stays open
-- while a second one is opened and closed with every close raising, until the free control is
--
-- * below one worst-case transaction: the next removal can never be granted ('grantStuck'), or
-- * within one job record above it: the removal is granted, its first job's record cannot be
--   charged, its transaction ends and nothing is in flight ('notePressure').
--
-- After the first 64 kept failures every held close takes exactly one backing record (4,096 bytes),
-- less than a job's record, so the free control cannot step over the second window.
module Test.TerrainRuntime.Backed.Held (spec) where

import Control.Concurrent.STM
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.List (isInfixOf)
import qualified Data.Text as Text
import Data.Word (Word64)
import Hetoimasia.Terrain.Runtime
import Hetoimasia.Terrain.Runtime.Settlement
import Hetoimasia.Terrain.Runtime.Storage.Internal.Native (NativeOp (..))
import Hetoimasia.Terrain.Runtime.Storage.Internal.Service (maxRecordControlBytes)
import qualified Hetoimasia.Terrain.Runtime.Store.Internal.Admission as A
import Hetoimasia.Terrain.Runtime.Store.Internal.Plan (RamCharge (..))
import System.IO (hPutStrLn, stderr)
import Test.Hspec
import Test.TerrainRuntime.Fixtures
import qualified Test.TerrainRuntime.Storage.Harness as H

data Ending
  = -- | the next transaction can never be funded
    NeverFunded
  | -- | a granted transaction's job is refused for pressure with nothing in flight
    RefusedWithNothingInFlight
  deriving stock (Eq, Show, Enum, Bounded)

isClose ∷ NativeOp → Bool
isClose = \case OpCloseFile {} → True; _ → False

spec ∷ Spec
spec = describe "Held closes that take the control account's room" $
  forM_' [minBound .. maxBound] $ \ending →
    it ("end the owner with a recorded defect naming them, never a wait (" <> show ending <> ")") (heldCase ending)
  where
    forM_' xs f = mapM_ f xs

heldCase ∷ Ending → IO ()
heldCase ending = do
  probe ← H.newProbe
  let arenas = 2 ∷ Int
      readers = 2 ∷ Integer
      w = A.worstTransactionCharge
      txnControl = fromIntegral (ramPagePins w + ramRootControl w + ramContinuation w) ∷ Word64
      need = A.controlNeedOf A.defaultEditBankSpec {A.ebsArenas = toInteger arenas, A.ebsReadersPerArena = readers} + toInteger (maxRecordControlBytes arenas)
      config = defaultConfig {configMaxArenas = arenas, configEditBank = A.defaultEditBankSpec {A.ebsControl = need, A.ebsReadersPerArena = readers}}
      done free = case ending of
        NeverFunded → free < txnControl
        RefusedWithNothingInFlight → free < txnControl + 4096
  withServiceSeam quiet config alwaysAdmitting noProbe (H.seamFor probe) $ \svc → do
    (_, lease) ← openMain svc "main"
    waitFor (backedAtRestSTM svc >>= check)
    H.addRule probe (-1) isClose H.Throw
    cycles ← newIORef (0 ∷ Int)
    let freeControl = (\l → A.lgControlLimit l - A.lgControlReserved l) <$> atomically (inspectEditBankSTM svc)
        cycleOnce = do
          (_, other) ← openMain svc "other"
          okOf (releaseLease svc other)
          waitFor (backedAtRestSTM svc >>= check)
          modifyIORef' cycles (+ 1)
        loop = freeControl >>= \free → if done free then pure free else cycleOnce >> loop
    free ← loop
    n ← readIORef cycles
    hPutStrLn stderr ("held closes example (" <> show ending <> "): " <> show n <> " held closes, free control " <> show free <> " against a transaction's " <> show txnControl)
    case ending of
      RefusedWithNothingInFlight → (free >= txnControl) `shouldBe` True
      NeverFunded → pure ()
    host ← newHost True
    _ ← okOf (removeWith svc (hostEndpoint svc Nothing host) lease (tile 3 4 5) Nothing)
    -- the owner ends, and its end settles the removal: nothing waits
    awaitOwnerStopped svc
    _ ← waitFor (readTVar (hostSettled host) >>= \s → if null s then retry else pure s)
    defects ← inspectDefects svc
    let expected = case ending of
          NeverFunded → "the next transaction can never be granted"
          RefusedWithNothingInFlight → "refused work for pressure that nothing in flight can relieve"
        named = [t | OwnerDefect t ← defects, expected `isInfixOf` Text.unpack t, ("held closes: " <> show n) `isInfixOf` Text.unpack t]
    (defects, length named) `shouldSatisfy` ((>= 1) . snd)
