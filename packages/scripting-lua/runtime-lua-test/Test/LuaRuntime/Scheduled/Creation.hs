-- | Creation, readiness and identity (requirements 12 and 13): a scheduled owner
-- is ready only after its configured initialization, its configuration is
-- validated before anything starts, and any number of owners and tasks can be
-- created and retired across cycles without an identity being issued twice.
module Test.LuaRuntime.Scheduled.Creation (spec) where

import Control.Concurrent (forkIO, killThread)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar, tryTakeMVar)
import Control.Exception (AsyncException (ThreadKilled), SomeException, fromException, throwIO, try)
import Control.Monad (forM, forM_, replicateM)
import Data.ByteString (ByteString)
import Data.List (isInfixOf)
import Data.Maybe (isNothing)
import qualified Data.Set as Set
import qualified Data.Text.Encoding as Text
import Data.Text (Text)
import Hetoimasia.Foundation.Resource (cleanupFailures, displayCleanupFailure)
import Hetoimasia.Scripting.Lua.Owner (ChunkName, chunkName)
import Hetoimasia.Scripting.Lua.Runtime (ownerIdentity, retireOwner)
import Hetoimasia.Scripting.Lua.Scheduled
import Hetoimasia.Scripting.Lua.Value (Value (VInteger))
import Test.Hspec (Spec, describe, it, shouldBe, shouldSatisfy)
import Test.LuaRuntime.Scheduled.Support
import Test.LuaRuntime.Scheduler.Support (allRegs)
import Test.LuaRuntime.Support (bounded, failExample, Gated (..), newFixture, optionalPolicy, quickSpec, requiredPolicy, startOwner, withBoundary, withBoundaryOpening)

-- | An initial chunk that runs the Lua given, under the name @init@.
initial ∷ Text → [(ChunkName, ByteString)]
initial source = [(chunkName "init", Text.encodeUtf8 source)]

spec ∷ Spec
spec = describe "creation, readiness and identity" $ do
  it "is ready only once its configured initialization has run" $ bounded $ do
    fixture ← newSFixture
    withBoundaryOpening [openAllGates fixture] $ \_ runtime → do
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
        _ → failExample "expected the optional owner to be unavailable"
      ticket ← admitTask' fixture bystander "echo" (request "echo" [VInteger 2] OrdinaryClass OneShot Nothing)
      outcomeOf ticket >>= (`shouldBe` Just [VInteger 2]) . taskReturned
      retireScheduled bystander

  it "tells the application once that an abandoned start is being abandoned, after the worker was asked to stop and before the starter waits for it to end" $ bounded $ do
    fixture ← newSFixture
    withBoundaryOpening [openAllGates fixture] $ \_ runtime → do
      told ← newEmptyMVar
      let config =
            (withChunks (initial "fx.block('init')") (scheduled fixture "abandoned" requiredPolicy defaultSchedulerBounds))
              {scheduledOnStartAbandoned = putMVar told ()}
      returned ← newEmptyMVar
      starter ← forkIO (try @SomeException (startScheduledOwner runtime config) >>= putMVar returned . either (const ()) (const ()))
      -- the initial chunk is running, held inside a binding: the start is in its readiness wait
      awaitEntered fixture "init"
      killThread starter
      -- the application is told while the worker is still held, so the starter has not returned
      takeMVar told
      tryTakeMVar returned >>= (`shouldSatisfy` isNothing)
      releaseGate fixture "init"
      takeMVar returned

  it "keeps what the hook raises as a failure of the host beside the failure of the start, never in place of it" $ bounded $ do
    fixture ← newSFixture
    withBoundaryOpening [openAllGates fixture] $ \_ runtime → do
      let config =
            (withChunks (initial "fx.block('init')") (scheduled fixture "abandoned, hook raises" requiredPolicy defaultSchedulerBounds))
              {scheduledOnStartAbandoned = throwIO (userError "the hook failed")}
      returned ← newEmptyMVar
      starter ← forkIO (try @SomeException (startScheduledOwner runtime config) >>= putMVar returned)
      awaitEntered fixture "init"
      killThread starter
      releaseGate fixture "init"
      takeMVar returned >>= \case
        Left failure → do
          -- the cancellation that abandoned the start is what is raised, as itself, with the hook's failure beside it
          fromException failure `shouldBe` Just ThreadKilled
          map displayCleanupFailure (cleanupFailures failure) `shouldSatisfy` any (isInfixOf "the hook failed")
        Right _ → failExample "the start was cancelled and should not have returned an owner"

  it "abandons a start as it always did when the application says nothing: the cancellation is raised as itself once the worker has ended" $ bounded $ do
    fixture ← newSFixture
    withBoundaryOpening [openAllGates fixture] $ \_ runtime → do
      let config = withChunks (initial "fx.block('init')") (scheduled fixture "abandoned, default" requiredPolicy defaultSchedulerBounds)
      returned ← newEmptyMVar
      starter ← forkIO (try @SomeException (startScheduledOwner runtime config) >>= putMVar returned)
      awaitEntered fixture "init"
      killThread starter
      releaseGate fixture "init"
      takeMVar returned >>= \case
        Left failure → do
          fromException failure `shouldBe` Just ThreadKilled
          map displayCleanupFailure (cleanupFailures failure) `shouldBe` []
        Right _ → failExample "the start was cancelled and should not have returned an owner"

  it "tells nobody of a start that is not abandoned, and by default nothing" $ bounded $ do
    fixture ← newSFixture
    withBoundary $ \_ runtime → do
      told ← newEmptyMVar
      let config = (scheduled fixture "kept" requiredPolicy defaultSchedulerBounds) {scheduledOnStartAbandoned = putMVar told ()}
      owner ← startScheduled fixture runtime config
      tryTakeMVar told >>= (`shouldSatisfy` isNothing)
      retireScheduled owner

  it "refuses an invalid configuration before any worker starts, naming every violation" $ bounded $ do
    fixture ← newSFixture
    withBoundary $ \_ runtime → do
      let bad = defaultSchedulerBounds {boundQuanta = Quanta (Quantum 0) (Quantum 4) (Quantum 4), boundOutstandingGrants = 0}
      outcome ← try @SomeException (startScheduledOwner runtime (scheduled fixture "refused" requiredPolicy bad))
      case outcome of
        Left failure → case fromException failure of
          Just (SchedulerRefused _) → pure ()
          Nothing → failExample ("expected the refusal of the configuration, found " <> show failure)
        Right _ → failExample "the configuration should have been refused"
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
            _ → failExample "expected the task to be accepted"
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
