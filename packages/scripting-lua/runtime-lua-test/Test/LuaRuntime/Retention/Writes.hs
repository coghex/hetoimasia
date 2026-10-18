-- | A retirement reading reads where the work has got to, and nothing it writes is kept (the
-- owner's decision on #488): a reading that writes a sentinel TVar and answers pending, or
-- complete, leaves the sentinel as it was, and completion still gives the work's accounting
-- back. Covered through the public interfaces of the request service, the subscription service
-- (both through 'ProviderWork') and the leases ('retireAsynchronously').
--
-- Each reading is counted on every execution, so that an example knows the pending answer was
-- polled before it lets the provider complete, and that the complete answer was polled after.
-- Nothing sleeps.
module Test.LuaRuntime.Retention.Writes (spec) where

import Control.Concurrent.STM (atomically, modifyTVar', newTVarIO, readTVarIO, writeTVar)
import Data.IORef (newIORef, readIORef)
import qualified Data.Map.Strict as Map
import Hetoimasia.Scripting.Lua.Instance
import Hetoimasia.Scripting.Lua.Lease
import Hetoimasia.Scripting.Lua.Provider
import Hetoimasia.Scripting.Lua.Scheduled
import Test.Hspec (Spec, describe, it, shouldBe, shouldSatisfy)
import Test.LuaRuntime.Instance.Lease.Support (LFix (lfBase), liveFor, newLFix, summaryOf)
import Test.LuaRuntime.Instance.Support
import Test.LuaRuntime.Request.Support
import Test.LuaRuntime.Retention.Leases (World (..), pair, staleSpec)
import Test.LuaRuntime.Retention.Probe
import Test.LuaRuntime.Scheduled.Support (awaitScheduledTerminal)
import qualified Test.LuaRuntime.Subscription.Support as Sub
import Test.LuaRuntime.Support (bounded, requiredPolicy, withBoundary)

spec ∷ Spec
spec = describe "a retirement reading's writes" $ do
  it "are not kept for a request's work, whether the reading answers pending or complete, and completion still gives the accounting back" $ bounded $ do
    fixture ← newIFixture
    fake ← newFake
    trace ← newTrace
    probe ← newProbe trace "a"
    sentinel ← newTVarIO (0 ∷ Int)
    let base = fakeEndpoint fake "path"
        writing =
          base
            { endpointSubmit = \submission → do
                work ← endpointSubmit base submission
                pure work {workRetirement = instrument probe (modifyTVar' sentinel (+ 1) >> workRetirement work)}
            }
        grant = RequestGrant [writing] 4 SettleOnArrival
    withBoundary $ \_ runtime → providersFinish fake $ do
      owner ← startRequester fixture runtime "reading writes, requests" [asker] cmdConfig grant requiredPolicy
      admitAsker fixture owner "i" "asker"
      command fixture owner "i" "start" "a"
      awaitLine fixture "cmd start a started"
      command fixture owner "i" "cancel" "a"
      awaitLine fixture "cmd cancel a cancelled"
      -- The reading has answered pending, and what it wrote is gone.
      awaitRuns probe 1
      readTVarIO sentinel >>= (`shouldBe` 0)
      before ← totalRuns probe
      finishWork fake 0
      awaitDiagnostic owner ((== 0) . rdWorkPending)
      -- It has answered complete, and what it wrote is gone too; the work's accounting is back.
      totalRuns probe >>= (`shouldSatisfy` (> before))
      readTVarIO sentinel >>= (`shouldBe` 0)
      awaitLine fixture "disposed 0"
      command fixture owner "i" "take" "a"
      awaitLine fixture "cmd take a {reason=owner,status=cancelled}"
      awaitDiagnostic owner ((== 0) . rdOutstanding)

  it "are not kept for a subscription's work, whether the reading answers pending or complete, and completion still gives the accounting back" $ bounded $ do
    fixture ← newIFixture
    fake ← Sub.newFakeEvents
    trace ← newTrace
    probe ← newProbe trace "s"
    sentinel ← newTVarIO (0 ∷ Int)
    let base = Sub.ticksEndpoint fake
        writing =
          base
            { eventSubscribe = \subscription → do
                work ← eventSubscribe base subscription
                pure work {workRetirement = instrument probe (modifyTVar' sentinel (+ 1) >> workRetirement work)}
            }
        grant = SubscriptionGrant [writing] 4 16
    withBoundary $ \_ runtime → Sub.eventsFinish fake $ do
      owner ← Sub.startSubscriber fixture runtime "reading writes, subscriptions" [Sub.subscriber] Sub.subConfig SettleOnArrival grant requiredPolicy
      Sub.admitSubscriber fixture owner "i" "subscriber"
      Sub.commandWith fixture owner "i" "subscribe" "a" (Just "ticks") Nothing
      awaitLine fixture "cmd subscribe a ok"
      Sub.commandWith fixture owner "i" "unsubscribe" "a" Nothing Nothing
      awaitRuns probe 1
      readTVarIO sentinel >>= (`shouldBe` 0)
      before ← totalRuns probe
      Sub.finishSubscription fake 0
      Sub.awaitSubDiagnostic owner ((== 0) . sdRetiring)
      totalRuns probe >>= (`shouldSatisfy` (> before))
      readTVarIO sentinel >>= (`shouldBe` 0)
      Sub.awaitSubDiagnostic owner (\reading → sdCharged reading == 0 && sdLive reading == 0)

  it "are not kept for a lease's retirement, whether the reading answers pending or complete, and completion still gives the accounting back" $ bounded $ do
    fixture ← newLFix 4
    trace ← newTrace
    sharedVar ← newTVarIO (0 ∷ Int)
    sentinel ← newTVarIO (0 ∷ Int)
    providers ← newIORef Map.empty
    first ← newProbe trace "a"
    second ← newProbe trace "b"
    let world = World sharedVar providers (Map.fromList [("a", first), ("b", second)]) (Just sentinel)
        base = lfBase fixture
    withBoundary $ \control runtime → do
      owner ← startWith base runtime (staleSpec fixture world "reading writes, leases" [pair])
      _ ← admit base owner "p" (moduleNamed "stalepair")
      awaitPhase base owner "p" Active
      liveFor fixture "p" 2
      retireScheduled owner
      awaitRuns first 1
      awaitRuns second 1
      readTVarIO sentinel >>= (`shouldBe` 0)
      before ← (+) <$> totalRuns first <*> totalRuns second
      held ← readIORef providers
      atomically (mapM_ (`writeTVar` ProviderComplete) (Map.elems held))
      _ ← awaitScheduledTerminal control owner
      after ← (+) <$> totalRuns first <*> totalRuns second
      after `shouldSatisfy` (> before)
      readTVarIO sentinel >>= (`shouldBe` 0)
      summary ← summaryOf fixture "p"
      (summaryPending summary, summaryCharged summary) `shouldBe` (0, 0)
