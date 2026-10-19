-- | The retirement of the runner's owner: it completes before a failure propagates, whoever latched it,
-- and waiting for it never holds the runner's thread against a cancellation.
module Test.LuaRuntime.Runner.Retirement (spec) where

import Control.Concurrent (myThreadId, throwTo)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar, tryReadMVar)
import Control.Exception (Exception, ExceptionWithContext (ExceptionWithContext), SomeException, finally, fromException, try)
import Control.Monad (void)
import Data.Maybe (isJust, isNothing)
import Hetoimasia.Scripting.Lua.Runtime (ownerEndpoint)
import Hetoimasia.Scripting.Lua.Value (Value (VText))
import Test.Hspec (Spec, describe, it, shouldReturn, shouldSatisfy)
import Test.LuaRuntime.Runner.Support
import qualified Test.LuaRuntime.Support as Base
import Test.LuaRuntime.Support (bounded, brokenIs, expectFatal, quickSpec, startOwner, submit, withBoundary)

-- | What a test throws to the runner's thread to cancel it.
data Cancelling = Cancelling
  deriving (Show)

instance Exception Cancelling

spec ∷ Spec
spec = describe "retirement" $ do
  it "completes before the run propagates a failure another supervised worker latched" $ bounded $ do
    fixture ← newRFixture
    other ← Base.newFixture
    returned ← newEmptyMVar
    observed ← newEmptyMVar
    withScripts [("e.lua", lua ["function shutdown(self, reason) fx.block('shutdown') fx.record('shutdown ' .. reason) end"])] $ \paths → do
      ExceptionWithContext _ failure ← expectFatal $ \control runtime → do
        owner ← startOwner runtime (quickSpec other "other" ["app"])
        void (submit (ownerEndpoint owner) "block_then_fail" [VText "go", VText "host"] >>= Base.accepted)
        alongside
          ( do
              -- The run waits, the instance is up: another worker fails, which latches and asks every worker to stop.
              awaitOut fixture 3
              Base.releaseGate other "go"
              -- The runner's owner is inside the instance's shutdown hook, held. The run has not returned: the
              -- retirement is not over, and the owner's worker is still outstanding.
              awaitGate fixture "shutdown"
              notReturned ← isNothing <$> tryReadMVar returned
              workers ← outstanding control
              putMVar observed (notReturned, workers >= 1)
              openGate fixture "shutdown"
          )
          (void (run fixture runtime (config fixture [noWait (scriptAt paths 0)])) `finally` putMVar returned ())
      -- The original failure propagated, and only after the hook ran to its end.
      failure `shouldSatisfy` brokenIs "host"
      takeMVar observed `shouldReturn` (True, True)
      recorded fixture `shouldReturn` ["shutdown stopped"]

  it "can be cancelled while it waits for a held segment, and keeps the owner asked to stop" $ bounded $ do
    fixture ← newRFixture
    withScripts [("slow.lua", lua ["function run(self) fx.block('hold') fx.record('finished') end"])] $ \paths →
      withBoundary $ \control runtime → do
        runner ← myThreadId
        stillHeld ← newEmptyMVar
        outcome ←
          alongside
            ( do
                -- The segment is held, the stop request is set, and the run has asked its owner to retire: it
                -- waits for the owner, which cannot end while the segment is held.
                awaitGate fixture "hold"
                setStop fixture True
                awaitRetiring fixture 0
                -- Cancelling the runner's thread is delivered to the wait, which nothing makes uninterruptible.
                throwTo runner Cancelling
                -- The owner is still there, held: the cancellation did not wait for it.
                outstanding control >>= putMVar stillHeld
                openGate fixture "hold"
            )
            (try @SomeException (runTick fixture runtime (config fixture [noWait (scriptAt paths 0)])))
        case outcome of
          Left raised → (fromException raised ∷ Maybe Cancelling) `shouldSatisfy` isJust
          Right _ → fail "the run returned instead of being cancelled"
        takeMVar stillHeld >>= (`shouldSatisfy` (>= 1))
