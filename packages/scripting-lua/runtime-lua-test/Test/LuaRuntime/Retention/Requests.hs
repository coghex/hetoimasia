-- | A retirement reading polled by the engine is not re-run against a stale view of a
-- transaction that has already read what another thread then commits to (#488).
--
-- Each example forces exactly one conflicting commit while the engine is polling a reading:
-- the reading's first execution holds a gate inside the engine's own transaction, the example
-- commits, and the gate opens. The reading is counted on every execution, including the
-- attempts a rolled-back transaction discards, and from the commit until the engine reports the
-- work over it may run at most 'bound' times. Nothing sleeps.
module Test.LuaRuntime.Retention.Requests (spec) where

import Control.Concurrent.STM (STM, atomically, modifyTVar', newTVarIO, readTVar)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Word (Word64)
import Hetoimasia.Scripting.Lua.Provider
import Test.Hspec (Spec, describe, it, shouldBe, shouldSatisfy)
import Test.LuaRuntime.Instance.Support
import Test.LuaRuntime.Request.Support
import Test.LuaRuntime.Retention.Probe
import Test.LuaRuntime.Support (bounded, requiredPolicy, withBoundary)

-- | The most times a reading may run from the one conflicting commit until the engine reports
-- the work over.
bound ∷ Int
bound = 20

-- | The fake provider's endpoint with its readings instrumented: the nth request's reading is
-- run through this probe (if it has one), after reading what the example says it also reads.
instrumented ∷ Fake → Map Word64 (Probe, STM ()) → RequestEndpoint
instrumented fake probes =
  base
    { endpointSubmit = \submission → do
        work ← endpointSubmit base submission
        pure $ case Map.lookup (infoNumber (submissionInfo submission)) probes of
          Just (probe, extra) → work {workRetirement = instrument probe (extra >> workRetirement work)}
          Nothing → work
    }
  where
    base = fakeEndpoint fake "path"

spec ∷ Spec
spec = describe "a retirement reading polled by the request service" $ do
  it "is not re-run against a stale view when another request of the owner is answered while it is polled" $ bounded $ do
    fixture ← newIFixture
    fake ← newFake
    trace ← newTrace
    probe ← newGatedProbe trace "a"
    let grant = RequestGrant [instrumented fake (Map.fromList [(1, (probe, pure ()))])] 4 SettleOnArrival
    withBoundary $ \_ runtime → providersFinish fake $ do
      owner ← startRequester fixture runtime "stale reading, service state" [asker] cmdConfig grant requiredPolicy
      admitAsker fixture owner "i" "asker"
      command fixture owner "i" "start" "a"
      awaitLine fixture "cmd start a started"
      command fixture owner "i" "start" "b"
      awaitLine fixture "cmd start b started"
      -- Cancelling the first makes the engine poll its reading, whose first execution holds the
      -- gate inside the engine's transaction, after the engine has read the service's state.
      command fixture owner "i" "cancel" "a"
      awaitLine fixture "cmd cancel a cancelled"
      entered ← awaitEntry probe
      entered `shouldBe` ["a"]
      -- The one conflicting commit: the other request's reply writes the service's state.
      commitThen probe (answerResult fake 1 5 >>= (`shouldBe` ReplySettled))
      finishWork fake 0
      awaitDiagnostic owner ((== 0) . rdWorkPending)
      runsAfterCommit probe >>= (`shouldSatisfy` (<= bound))

  it "is not re-run against a stale view when the provider commits to a TVar two requests' readings share" $ bounded $ do
    fixture ← newIFixture
    fake ← newFake
    trace ← newTrace
    sharedVar ← newTVarIO (0 ∷ Int)
    first ← newProbe trace "a"
    second ← newGatedProbe trace "b"
    let reads' = () <$ readTVar sharedVar
        grant = RequestGrant [instrumented fake (Map.fromList [(1, (first, reads')), (2, (second, reads'))])] 4 SettleOnArrival
    withBoundary $ \_ runtime → providersFinish fake $ do
      owner ← startRequester fixture runtime "stale reading, provider state" [asker] cmdConfig grant requiredPolicy
      admitAsker fixture owner "i" "asker"
      command fixture owner "i" "start" "a"
      awaitLine fixture "cmd start a started"
      command fixture owner "i" "start" "b"
      awaitLine fixture "cmd start b started"
      command fixture owner "i" "cancel" "a"
      awaitLine fixture "cmd cancel a cancelled"
      command fixture owner "i" "cancel" "b"
      awaitLine fixture "cmd cancel b cancelled"
      -- The second reading's first execution holds the gate; the first ran just before it, in
      -- the same polling transaction, and so read the sharedVar TVar earlier in it.
      entered ← awaitEntry second
      take 2 entered `shouldBe` ["b", "a"]
      -- The one conflicting commit: the provider's own thread writes the sharedVar TVar.
      commitThen second (atomically (modifyTVar' sharedVar (+ 1)))
      finishWork fake 0
      finishWork fake 1
      awaitDiagnostic owner ((== 0) . rdWorkPending)
      runsAfterCommit second >>= (`shouldSatisfy` (<= bound))
