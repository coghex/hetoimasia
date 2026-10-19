-- | A retirement reading reads where the work has got to, and nothing it writes is kept (the
-- owner's decision on #488): a reading that writes a sentinel TVar and answers pending, or
-- complete, leaves the sentinel as it was, and completion still gives the work's accounting
-- back. Covered through the public interfaces of the request service, the subscription service
-- (both through 'ProviderWork') and the leases ('retireAsynchronously').
--
-- A sentinel that is unchanged proves nothing until a transaction that polled the reading has
-- committed: a write is invisible to everyone until then, kept or not. So no example looks at
-- the sentinel on the strength of the reading having started. Each makes the owner serve more
-- after the reading has been asked about pending work (two more commands, or two more events, each
-- followed by a boundary that polls it in a transaction that commits, and which on the code
-- before the fix leaves the sentinel written), and waits for an execution that answered
-- pending. It then lets the provider complete, waits for the engine to report the work over
-- (which it only does in a transaction that commits) and for an execution that answered
-- complete. Nothing sleeps.
module Test.LuaRuntime.Retention.Writes (spec) where

import Control.Concurrent (yield)
import Control.Exception (finally)
import Control.Concurrent.STM (atomically, modifyTVar', newTVarIO, readTVarIO, writeTVar)
import Data.IORef (newIORef, readIORef)
import Data.Text (Text)
import qualified Data.Map.Strict as Map
import Hetoimasia.Scripting.Lua.Instance
import Hetoimasia.Scripting.Lua.Lease
import Hetoimasia.Scripting.Lua.Provider
import Hetoimasia.Scripting.Lua.Scheduled
import Test.Hspec (Spec, describe, it, shouldBe, shouldSatisfy)
import Test.LuaRuntime.Instance.Lease.Support (LFix (lfBase), awaitSummary, liveFor, marker, newLFix, summaryOf)
import Test.LuaRuntime.Instance.Support
import Test.LuaRuntime.Request.Support
import Test.LuaRuntime.Retention.Leases (World (..), pairOnTick, staleSpec)
import Test.LuaRuntime.Retention.Probe
import Test.LuaRuntime.Scheduled.Support (awaitScheduledTerminal)
import qualified Test.LuaRuntime.Subscription.Support as Sub
import Test.LuaRuntime.Support (bounded, requiredPolicy, withBoundary)

-- | Wait, without sleeping, until this many lines of this kind have been recorded.
awaitMany ∷ IFixture → Text → Int → IO ()
awaitMany fixture entry wanted = do
  seen ← logCount fixture entry
  if seen >= wanted then pure () else yield >> awaitMany fixture entry wanted

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
                pure work {workRetirement = instrumentAnswering probe (modifyTVar' sentinel (+ 1) >> workRetirement work)}
            }
        grant = RequestGrant [writing] 4 SettleOnArrival
    withBoundary $ \_ runtime → providersFinish fake $ do
      owner ← startRequester fixture runtime "reading writes, requests" [asker] cmdConfig grant requiredPolicy
      admitAsker fixture owner "i" "asker"
      command fixture owner "i" "start" "a"
      awaitLine fixture "cmd start a started"
      command fixture owner "i" "cancel" "a"
      awaitLine fixture "cmd cancel a cancelled"
      -- The owner has served two more commands since the work was asked about, each followed by
      -- a boundary that polled it and committed; the reading has answered pending.
      command fixture owner "i" "noop" "n1"
      awaitLine fixture "cmd noop n1 noop"
      command fixture owner "i" "noop" "n2"
      awaitLine fixture "cmd noop n2 noop"
      awaitAnswer probe AnsweredPending
      readTVarIO sentinel >>= (`shouldBe` 0)
      finishWork fake 0
      awaitDiagnostic owner ((== 0) . rdWorkPending)
      -- The engine reported the work over, so an execution answered complete, in a transaction
      -- that committed; what it wrote is gone too.
      answeredWith probe AnsweredComplete >>= (`shouldSatisfy` (>= 1))
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
                pure work {workRetirement = instrumentAnswering probe (modifyTVar' sentinel (+ 1) >> workRetirement work)}
            }
        grant = SubscriptionGrant [writing] 4 16
    withBoundary $ \_ runtime → Sub.eventsFinish fake $ do
      owner ← Sub.startSubscriber fixture runtime "reading writes, subscriptions" [Sub.subscriber] Sub.subConfig SettleOnArrival grant requiredPolicy
      Sub.admitSubscriber fixture owner "i" "subscriber"
      Sub.commandWith fixture owner "i" "subscribe" "a" (Just "ticks") Nothing
      awaitLine fixture "cmd subscribe a ok"
      Sub.commandWith fixture owner "i" "unsubscribe" "a" Nothing Nothing
      Sub.sync fixture owner "i" 1
      Sub.sync fixture owner "i" 2
      awaitAnswer probe AnsweredPending
      readTVarIO sentinel >>= (`shouldBe` 0)
      Sub.finishSubscription fake 0
      Sub.awaitSubDiagnostic owner ((== 0) . sdRetiring)
      answeredWith probe AnsweredComplete >>= (`shouldSatisfy` (>= 1))
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
    -- However the example ends the providers finish what they were asked to retire, so that a
    -- failing example fails instead of waiting for an owner that is right to wait.
    let finishRetirements = readIORef providers >>= \held → atomically (mapM_ (`writeTVar` ProviderComplete) (Map.elems held))
    withBoundary $ \control runtime → (`finally` finishRetirements) $ do
      owner ← startWith base runtime (staleSpec fixture world "reading writes, leases" [pairOnTick, marker])
      _ ← admit base owner "p" (moduleNamed "stalepairontick")
      _ ← admit base owner "m" (moduleNamed "marker")
      awaitPhase base owner "p" Active
      awaitPhase base owner "m" Active
      liveFor fixture "p" 2
      -- A tick makes the instance release both resources; their retirements are pending and
      -- the owner goes on serving.
      expectDelivered base owner "p" 1
      awaitSummary' fixture (== 2)
      -- Two more events, to another instance, each followed by a boundary that services the
      -- retirements in a transaction that commits.
      expectDelivered base owner "m" 1
      awaitMany base "ran marker" 1
      expectDelivered base owner "m" 2
      awaitMany base "ran marker" 2
      awaitAnswer first AnsweredPending
      awaitAnswer second AnsweredPending
      readTVarIO sentinel >>= (`shouldBe` 0)
      held ← readIORef providers
      atomically (mapM_ (`writeTVar` ProviderComplete) (Map.elems held))
      awaitSummary' fixture (== 0)
      awaitAnswer first AnsweredComplete
      awaitAnswer second AnsweredComplete
      readTVarIO sentinel >>= (`shouldBe` 0)
      summaryOf fixture "p" >>= \summary → (summaryPending summary, summaryCharged summary) `shouldBe` (0, 0)
      retireScheduled owner
      _ ← awaitScheduledTerminal control owner
      pure ()
  where
    awaitSummary' fixture wanted = awaitSummary fixture "p" (wanted . summaryPending)
