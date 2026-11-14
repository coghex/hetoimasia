-- | The owner's loop.
--
-- * NOTHING READY IS STARVED BY WORK THAT CANNOT PROGRESS. The chooser offers a piece of work only
--   when its step would change something (the commit's arbitration asks the same question as the
--   chooser, 'commitWaits'), and a storage wait that is met is ready work in its turn. An older open
--   whose host is not eligible holds a younger one back (opens publish in incarnation order), and
--   while it does, another arena's reads and writes settle; the younger open is never chosen in vain.
--   Every example of the suite checks that no work was chosen again after a step of it that changed
--   nothing ('inspectIdleRepeatsSTM', in the fixtures).
--
-- * EFFECT AND RECORD ARE NOT SEPARATED BY AN ASYNCHRONOUS EXCEPTION. The owner's loop runs masked;
--   only its deliberate wait is interruptible. An exception sent to the owner between a write's
--   submission and the record of its ticket ('PointSlotStepped', taken uninterruptibly) arrives after
--   the record: the owner ends with the job recorded, and the slot's credit (which covers the page
--   images the job holds) stays reserved while the job is in flight.
module Test.TerrainRuntime.Backed.Loop (spec) where

import Control.Concurrent (forkIO, myThreadId, throwTo)
import Control.Concurrent.STM
import Control.Exception (Exception, SomeException, finally, fromException, try)
import Control.Monad (void)
import qualified Data.Text as Text
import Hetoimasia.Terrain.Runtime
import Hetoimasia.Terrain.Runtime.Settlement
import Hetoimasia.Terrain.Runtime.Storage.Internal.Native (NativeOp (..))
import qualified Hetoimasia.Terrain.Runtime.Store.Internal.Admission as A
import Test.Hspec
import Test.Support.Bounded (bounded)
import Test.TerrainRuntime.Fixtures
import qualified Test.TerrainRuntime.Storage.Harness as H

-- | The exception the example sends the owner.
data Sent = Sent
  deriving stock (Show)

instance Exception Sent

isWrite ∷ NativeOp → Bool
isWrite = \case OpWriteAt {} → True; _ → False

spec ∷ Spec
spec = describe "The owner's loop" $ do
  it "lets another arena's reads and writes settle while an older open's host is not eligible, never choosing the younger open in vain, and publishes both opens in order once it is" $
    withServiceUsing defaultConfig alwaysAdmitting noProbe $ \svc → do
      client ← okOf (registerClient svc)
      other ← okOf (openArena svc client "other" soilOverStone) >>= await svc >>= expectSuccess
      older ← newHost False
      younger ← newHost True
      _ ← okOf (openArenaWith svc (hostEndpoint svc Nothing older) client "older" soilOverStone)
      _ ← okOf (openArenaWith svc (hostEndpoint svc Nothing younger) client "younger" soilOverStone)
      -- both are prepared and staged; the younger one's host is eligible, the older one's is not
      forM_' [older, younger] $ \host → waitFor (readTVar (hostReady host) >>= \n → check (n >= 1))
      -- another arena's write and read go through its storage jobs and settle meanwhile
      _ ← bounded (removeCell' svc other (tile 3 4 5))
      answer ← bounded (readCell svc other (tile 3 4 5))
      cellIs answer `shouldBe` True
      -- the younger open waits for the older one: neither has settled
      settledOf older `shouldReturn` []
      settledOf younger `shouldReturn` []
      grant older
      forM_' [older, younger] $ \host → waitFor (readTVar (hostSettled host) >>= \s → check (not (null s)))
      outcomes ← mapM settledOf [older, younger]
      outcomes `shouldSatisfy` all opened

  it "records a write's ticket before an exception sent to the owner at the step that submitted it arrives, and keeps the slot's credit while the job is in flight" $ do
    probe ← H.newProbe
    owner ← newEmptyTMVarIO
    atStep ← newEmptyTMVarIO
    release ← newEmptyTMVarIO
    let points = Probe $ \case
          PointSlotStepped _ phase | phase == "writing" → do
            tid ← myThreadId
            -- announced in one transaction, held in the next (a wait in the same transaction would undo
            -- the announcement)
            atomically $ do
              _ ← tryPutTMVar owner tid
              void (tryPutTMVar atStep ())
            atomically (readTMVar release)
          _ → pure ()
    ended ← try $ withServiceSeam quiet defaultConfig alwaysAdmitting points (H.seamFor probe) $ \svc → do
      client ← okOf (registerClient svc)
      lease ← okOf (openArena svc client "main" soilOverStone) >>= await svc >>= expectSuccess
      waitFor (backedAtRestSTM svc >>= check)
      -- the write's native call is held: once submitted, the job stays in flight
      writes ← H.addGate probe isWrite
      -- every exit lets the write go (a failing assertion must not leave the scope's drain waiting)
      flip finally (H.openGate writes >> atomically (void (tryPutTMVar release ()))) $ do
       host ← newHost True
       _ ← okOf (removeWith svc (hostEndpoint svc Nothing host) lease (tile 3 4 5) Nothing)
       -- the owner is between the write's submission and the record of its ticket
       waitFor (takeTMVar atStep)
       tid ← atomically (readTMVar owner)
       sent ← newEmptyTMVarIO
       void (forkIO (throwTo tid Sent >> atomically (putTMVar sent ())))
       atomically (putTMVar release ())
       bounded (awaitOwnerStopped svc)
       atomically (takeTMVar sent)
       -- the owner ended with the write's job recorded: its slot and the slot's credit are kept while
       -- the job is in flight
       ledger ← atomically (inspectEditBankSTM svc)
       A.lgStagingForeground ledger `shouldSatisfy` (> 0)
       jobs ← atomically (inspectStorageJobsSTM svc)
       jobs `shouldSatisfy` (> 0)
       -- the request settled once, by the owner's end
       waitFor (readTVar (hostSettled host) >>= \s → check (not (null s)))
       length <$> settledOf host `shouldReturn` 1
    case ended of
      Left (failure ∷ SomeException)
        | Just Sent <- fromException failure → pure ()
        | Text.isInfixOf "Sent" (Text.pack (show failure)) → pure ()
        | otherwise → expectationFailure ("the service ended with " <> show failure)
      Right () → pure ()
  where
    forM_' xs f = mapM_ f xs
    opened = \case
      [Succeeded (AOpened _)] → True
      _ → False
