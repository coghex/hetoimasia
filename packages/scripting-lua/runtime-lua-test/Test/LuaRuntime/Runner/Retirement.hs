-- | The owner of the runner never outlives the call: its retirement is complete before anything
-- propagates, however it began (a failure another worker latched, the runner's own failure, a
-- cancellation) and however many times the runner's thread is interrupted meanwhile.
--
-- Every example holds the owner at a gate inside Lua, so that "the call returned while the owner was
-- still running Lua" is something it can see: the held script writes a line to the sink when it is let
-- go, and the line must be there before the call returned. The example knows the runner's thread is
-- waiting for the owner by waiting for it to park in STM, never by waiting a while.
module Test.LuaRuntime.Runner.Retirement (spec) where

import Control.Concurrent (myThreadId, throwTo)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, tryReadMVar)
import Control.Concurrent.STM (atomically, retry)
import Control.Exception (AsyncException (ThreadKilled), Exception, ExceptionWithContext (ExceptionWithContext), finally, fromException, throwIO)
import Control.Monad (void)
import Data.IORef (atomicModifyIORef', readIORef)
import Data.Maybe (isJust, isNothing)
import Data.Text (Text)
import Hetoimasia.Foundation.Resource (cleanupFailureException, cleanupFailuresInContext)
import Hetoimasia.Runtime.Supervision (WorkerStatus (WorkerLive))
import Hetoimasia.Scripting.Lua.Runner
import Hetoimasia.Scripting.Lua.Runtime (ownerEndpoint, ownerStatus)
import Hetoimasia.Scripting.Lua.Value (Value (VText))
import Test.Hspec (Spec, describe, it, shouldBe, shouldReturn, shouldSatisfy)
import Test.LuaRuntime.Runner.Support
import qualified Test.LuaRuntime.Support as Base
import Test.LuaRuntime.Support (awaitBlockedOnSTM, bounded, Broken (Broken), brokenIs, expectFatalOpening, expectObserved, failExample, Gated (..), quickSpec, startOwner, submit, tryExpected, withBoundaryOpening)

-- | What a test throws to the runner's thread to cancel it.
data Cancelling = Cancelling
  deriving (Show)

instance Exception Cancelling

-- | The call has returned (or raised): noted among what the sinks were handed, in order.
markReturned ∷ RFixture → IO ()
markReturned fixture = atomicModifyIORef' (rfLines fixture) (\held → (("test", "returned") : held, ()))

-- | The held script's line was written before the call returned, and the call returned once.
expectWrittenBeforeReturn ∷ RFixture → Text → IO ()
expectWrittenBeforeReturn fixture word = do
  seen ← reverse <$> readIORef (rfLines fixture)
  [line | (_, line) ← seen, line == word || line == "returned"] `shouldBe` [word, "returned"]

spec ∷ Spec
spec = describe "retirement" $ do
  it "completes before the run propagates a failure another supervised worker latched" $ bounded $ do
    fixture ← newRFixture
    other ← Base.newFixture
    returned ← newEmptyMVar
    observed ← newEmptyMVar
    withScripts [("e.lua", lua ["function shutdown(self, reason) fx.block('shutdown') print('after') end"])] $ \paths → do
      ExceptionWithContext _ failure ← expectFatalOpening [openAllGates fixture, openAllGates other] $ \control runtime → do
        runner ← myThreadId
        owner ← startOwner runtime (quickSpec other "other" ["app"])
        void (submit (ownerEndpoint owner) "block_then_fail" [VText "go", VText "host"] >>= Base.accepted)
        Base.alongsideOpening [openAllGates fixture, openAllGates other]
          ( do
              -- The run waits, the instance is up: another worker fails, which latches and asks every worker to stop.
              awaitOut fixture 3
              Base.releaseGate other "go"
              awaitGate fixture "shutdown"
              -- The latch has been delivered to the runner's thread; it parks, waiting for the owner, which is
              -- held in the hook. It has not returned.
              awaitBlockedOnSTM runner
              notReturned ← isNothing <$> tryReadMVar returned
              workers ← outstanding control
              putMVar observed (notReturned, workers >= 1)
              openGate fixture "shutdown"
          )
          (void (run fixture runtime (config fixture [noWait (scriptAt paths 0)])) `finally` (markReturned fixture >> putMVar returned ()))
      -- The original failure propagated, and only after the hook ran to its end and wrote.
      failure `shouldSatisfy` brokenIs "host"
      expectObserved "the helper never observed the run waiting for the held owner: the latch was not delivered to the runner's thread before the bound let the owner go" observed `shouldReturn` (True, True)
      expectWrittenBeforeReturn fixture "after"

  it "completes before the run propagates a failure another supervised worker latched during startup" $ bounded $ do
    fixture ← newRFixture
    other ← Base.newFixture
    returned ← newEmptyMVar
    observed ← newEmptyMVar
    withScripts [("held.lua", lua ["fx.block('load')", "print('after')", "function run(self) end"])] $ \paths → do
      ExceptionWithContext _ failure ← expectFatalOpening [openAllGates fixture, openAllGates other] $ \control runtime → do
        runner ← myThreadId
        owner ← startOwner runtime (quickSpec other "other" ["app"])
        void (submit (ownerEndpoint owner) "block_then_fail" [VText "go", VText "host"] >>= Base.accepted)
        Base.alongsideOpening [openAllGates fixture, openAllGates other]
          ( do
              -- The owner is inside the module's top level, held, and the runner's thread is in creation's wait.
              awaitGate fixture "load"
              Base.releaseGate other "go"
              -- Supervision commits the other worker's failure and delivers it to creation, which must not
              -- return while the owner is held.
              atomically (ownerStatus owner >>= \case WorkerLive → retry; _ → pure ())
              awaitBlockedOnSTM runner
              notReturned ← isNothing <$> tryReadMVar returned
              workers ← outstanding control
              putMVar observed (notReturned, workers >= 1)
              openGate fixture "load"
          )
          (void (run fixture runtime (config fixture [noWait (scriptAt paths 0)])) `finally` (markReturned fixture >> putMVar returned ()))
      failure `shouldSatisfy` brokenIs "host"
      expectObserved "the helper never observed the other worker's failure while the owner was held: its terminal status was not readable until the owner was let go" observed `shouldReturn` (True, True)
      expectWrittenBeforeReturn fixture "after"

  it "completes before the run is cancelled during startup" $ bounded $ do
    fixture ← newRFixture
    withScripts [("held.lua", lua ["fx.block('load')", "print('after')", "function run(self) end"])] $ \paths →
      withBoundaryOpening [openAllGates fixture] $ \control runtime → do
        runner ← myThreadId
        returned ← newEmptyMVar
        observed ← newEmptyMVar
        outcome ←
          alongside fixture
            ( do
                awaitGate fixture "load"
                awaitBlockedOnSTM runner
                throwTo runner Cancelling
                -- The cancellation was delivered and is not the end of the call: the runner's thread parks again,
                -- waiting for the owner, which is still held.
                awaitBlockedOnSTM runner
                notReturned ← isNothing <$> tryReadMVar returned
                workers ← outstanding control
                putMVar observed (notReturned, workers >= 1)
                openGate fixture "load"
            )
            (tryExpected (run fixture runtime (config fixture [noWait (scriptAt paths 0)])) `finally` (markReturned fixture >> putMVar returned ()))
        case outcome of
          Left (ExceptionWithContext _ raised) → (fromException raised ∷ Maybe Cancelling) `shouldSatisfy` isJust
          Right _ → failExample "the run returned instead of being cancelled"
        expectObserved "the helper never observed the run waiting for the held owner after the cancellation: the bound let the owner go first" observed `shouldReturn` (True, True)
        expectWrittenBeforeReturn fixture "after"

  it "is not cut short by a cancellation while it waits for a held segment: the owner has ended before the cancellation propagates" $ bounded $ do
    fixture ← newRFixture
    withScripts [("slow.lua", lua ["function run(self) fx.block('hold') print('after') end"])] $ \paths →
      withBoundaryOpening [openAllGates fixture] $ \control runtime → do
        runner ← myThreadId
        returned ← newEmptyMVar
        observed ← newEmptyMVar
        outcome ←
          alongside fixture
            ( do
                -- The segment is held, the stop request is set, and the run has asked its owner to retire.
                awaitGate fixture "hold"
                setStop fixture True
                awaitRetiring fixture 0
                throwTo runner Cancelling
                awaitBlockedOnSTM runner
                notReturned ← isNothing <$> tryReadMVar returned
                workers ← outstanding control
                putMVar observed (notReturned, workers >= 1)
                openGate fixture "hold"
            )
            (tryExpected (runTick fixture runtime (config fixture [noWait (scriptAt paths 0)])) `finally` (markReturned fixture >> putMVar returned ()))
        case outcome of
          Left (ExceptionWithContext _ raised) → (fromException raised ∷ Maybe Cancelling) `shouldSatisfy` isJust
          Right _ → failExample "the run returned instead of being cancelled"
        expectObserved "the helper never observed the run waiting for the held segment after the cancellation: the bound let the segment go first" observed `shouldReturn` (True, True)
        expectWrittenBeforeReturn fixture "after"

  it "keeps draining when cleanup after a failure of the runner's own thread is interrupted, and keeps both failures" $ bounded $ do
    fixture ← newRFixture
    withScripts [("e.lua", lua ["function shutdown(self, reason) fx.block('shutdown') print('after') end"])] $ \paths →
      withBoundaryOpening [openAllGates fixture] $ \control runtime → do
        runner ← myThreadId
        returned ← newEmptyMVar
        observed ← newEmptyMVar
        -- The start table's write fails on the runner's own thread: that is the failure the retirement follows.
        let failingTable =
              (config fixture [noWait (scriptAt paths 0)])
                { runnerOutput = \line → do
                    atomicModifyIORef' (rfLines fixture) (\held → (("out", line) : held, ()))
                    if line == startTitle then throwIO (Broken "table sink") else pure ()
                }
        outcome ←
          alongside fixture
            ( do
                -- The owner is in the hook, held, and the run's cleanup is waiting for it. It is interrupted.
                awaitGate fixture "shutdown"
                awaitBlockedOnSTM runner
                throwTo runner ThreadKilled
                awaitBlockedOnSTM runner
                notReturned ← isNothing <$> tryReadMVar returned
                workers ← outstanding control
                putMVar observed (notReturned, workers >= 1)
                openGate fixture "shutdown"
            )
            (tryExpected (run fixture runtime failingTable) `finally` (markReturned fixture >> putMVar returned ()))
        expectObserved "the helper never observed the run waiting for the held owner after it was interrupted: the bound let the owner go first" observed `shouldReturn` (True, True)
        expectWrittenBeforeReturn fixture "after"
        case outcome of
          Left (ExceptionWithContext context raised) → do
            -- The cancellation propagates as itself, and the failure that was already propagating is kept beside it.
            (fromException raised ∷ Maybe AsyncException) `shouldSatisfy` isJust
            [brokenIs "table sink" evidence | found ← cleanupFailuresInContext context, let ExceptionWithContext _ evidence = cleanupFailureException found] `shouldSatisfy` or
          Right _ → failExample "the run returned instead of raising"
