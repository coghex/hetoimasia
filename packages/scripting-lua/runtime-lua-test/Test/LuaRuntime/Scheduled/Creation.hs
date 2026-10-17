-- | Creation, readiness and identity (requirements 12 and 13): a scheduled owner
-- is ready only after its configured initialization, its configuration is
-- validated before anything starts, and any number of owners and tasks can be
-- created and retired across cycles without an identity being issued twice.
module Test.LuaRuntime.Scheduled.Creation (spec) where

import Control.Concurrent (forkIO)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar, tryTakeMVar)
import Control.Exception (SomeException, fromException, try)
import Control.Monad (forM, forM_, replicateM)
import Data.ByteString (ByteString)
import Data.Maybe (isNothing)
import qualified Data.Set as Set
import qualified Data.Text.Encoding as Text
import Data.Text (Text)
import Hetoimasia.Scripting.Lua.Owner (ChunkName, chunkName)
import Hetoimasia.Scripting.Lua.Runtime (ownerIdentity, retireOwner)
import Hetoimasia.Scripting.Lua.Scheduled
import Hetoimasia.Scripting.Lua.Value (Value (VInteger))
import Test.Hspec (Spec, describe, it, shouldBe, shouldSatisfy)
import Test.LuaRuntime.Scheduled.Support
import Test.LuaRuntime.Scheduler.Support (allRegs)
import Test.LuaRuntime.Support (bounded, newFixture, optionalPolicy, quickSpec, requiredPolicy, startOwner, withBoundary)

-- | An initial chunk that runs the Lua given, under the name @init@.
initial ∷ Text → [(ChunkName, ByteString)]
initial source = [(chunkName "init", Text.encodeUtf8 source)]

spec ∷ Spec
spec = describe "creation, readiness and identity" $ do
  it "is ready only once its configured initialization has run" $ bounded $ do
    fixture ← newSFixture
    withBoundary $ \_ runtime → do
      let config = withChunks (initial "fx.block('init')") (scheduled fixture "slow init" requiredPolicy defaultSchedulerBounds)
      created ← newEmptyMVar
      _ ← forkIO (startScheduled fixture runtime config >>= putMVar created)
      -- The initial chunk is running, inside a binding.
      awaitEntered fixture "init"
      tryTakeMVar created >>= (`shouldSatisfy` isNothing)
      releaseGate fixture "init"
      owner ← takeMVar created
      ticket ← admitTask' fixture owner "echo" (request "echo" [VInteger 1] OrdinaryClass OneShot Nothing)
      outcomeOf ticket >>= (`shouldBe` Just [VInteger 1]) . taskReturned
      retireScheduled owner

  it "ends creation under the owner's policy when initialization fails, and leaves another owner serving" $ bounded $ do
    fixture ← newSFixture
    withBoundary $ \_ runtime → do
      bystander ← startScheduled fixture runtime (scheduled fixture "bystander" requiredPolicy defaultSchedulerBounds)
      let broken = withChunks (initial "error('init boom')") (scheduled fixture "broken" (optionalPolicy (const True)) defaultSchedulerBounds)
      startScheduledOwner runtime broken >>= \case
        ScheduledUnavailable _ → pure ()
        _ → fail "expected the optional owner to be unavailable"
      ticket ← admitTask' fixture bystander "echo" (request "echo" [VInteger 2] OrdinaryClass OneShot Nothing)
      outcomeOf ticket >>= (`shouldBe` Just [VInteger 2]) . taskReturned
      retireScheduled bystander

  it "refuses an invalid configuration before any worker starts, naming every violation" $ bounded $ do
    fixture ← newSFixture
    withBoundary $ \_ runtime → do
      let bad = defaultSchedulerBounds {boundQuanta = Quanta (Quantum 0) (Quantum 4) (Quantum 4), boundOutstandingGrants = 0}
      outcome ← try @SomeException (startScheduledOwner runtime (scheduled fixture "refused" requiredPolicy bad))
      case outcome of
        Left failure → case fromException failure of
          Just (SchedulerRefused _) → pure ()
          Nothing → fail ("expected the refusal of the configuration, found " <> show failure)
        Right _ → fail "the configuration should have been refused"
      -- Nothing was started or armed.
      length <$> allRegs (sfTimer fixture) >>= (`shouldBe` 0)

  it "never reissues an identity across many owners and tasks created and retired, more than two at once, beside finite-call owners" $ bounded $ do
    fixture ← newSFixture
    plain ← newFixture
    withBoundary $ \_ runtime → do
      cycles ← forM [1 .. 6 ∷ Int] $ \_ → do
        owners ← replicateM 4 (startScheduled fixture runtime (scheduled fixture "cycle" requiredPolicy defaultSchedulerBounds))
        finite ← startOwner runtime (quickSpec plain "finite" [])
        tasks ← forM owners $ \owner → forM [1 .. 5 ∷ Int] $ \n → do
          admitted ← admitScheduledTask (scheduledEndpoint owner) (request "echo" [VInteger (fromIntegral n)] OrdinaryClass OneShot Nothing)
          case admitted of
            TaskAccepted identity ticket → do
              _ ← outcomeOf ticket
              pure identity
            _ → fail "expected the task to be accepted"
        let ownerIds = map scheduledIdentity owners <> [ownerIdentity finite]
        forM_ owners retireScheduled
        retireOwner finite
        pure (ownerIds, concat tasks)
      let allOwners = concatMap fst cycles
          allTasks = concatMap snd cycles
      length allOwners `shouldBe` 6 * 5
      Set.size (Set.fromList allOwners) `shouldBe` length allOwners
      length allTasks `shouldBe` 6 * 4 * 5
      Set.size (Set.fromList allTasks) `shouldBe` length allTasks
