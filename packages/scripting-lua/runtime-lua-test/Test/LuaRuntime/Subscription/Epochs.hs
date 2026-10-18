-- | Epochs and generations (subscriptions): advancing an owner's epoch through the request
-- service's epoch operation invalidates its subscriptions while the accounting of the provider's
-- work is retained; a producer holding an old feed cannot reach a subscription made after it, in
-- the same epoch or a later one; and subscribing and unsubscribing over and over cannot reclaim a
-- place while a provider's retirement is pending.
module Test.LuaRuntime.Subscription.Epochs (spec) where

import Control.Monad (forM_, void, when)
import Data.IORef (writeIORef)
import Data.Text (Text)
import qualified Data.Text as Text
import Hetoimasia.Scripting.Lua.Instance
import Hetoimasia.Scripting.Lua.Owner (ModuleSource)
import Hetoimasia.Scripting.Lua.Provider
import Hetoimasia.Scripting.Lua.Runtime (LuaRuntime)
import Hetoimasia.Scripting.Lua.Scheduled
import Test.Hspec (Spec, describe, it, shouldBe, shouldSatisfy)
import Test.LuaRuntime.Instance.Support
import Test.LuaRuntime.Request.Support (awaitLine, refusalOf)
import Test.LuaRuntime.Scheduled.Support (SFixture (sfObserver), awaitEntered, blockOn, releaseGate)
import Test.LuaRuntime.Subscription.Support
import Test.LuaRuntime.Support (bounded, requiredPolicy, withBoundary)

-- | An owner of subscribers on elapsed time, granted both endpoints with this room for subscriptions.
ownerOf ∷ IFixture → FakeEvents → LuaRuntime → Text → [ModuleSource] → Int → IO ScheduledOwner
ownerOf fixture fake runtime label modules places =
  startSubscriber fixture runtime label modules subConfig SettleOnArrival (subGrant fake places 16) requiredPolicy

subscribeTo' ∷ IFixture → ScheduledOwner → Text → Text → Text → IO ()
subscribeTo' fixture owner name key endpoint = do
  commandWith fixture owner name "subscribe" key (Just endpoint) Nothing
  awaitLine fixture ("cmd subscribe " <> key <> " ok")

-- | Advance the owner's epoch, expecting it to have one to advance.
advance ∷ ScheduledOwner → IO EpochReport
advance owner =
  advanceRequestEpoch (scheduledEndpoint owner) >>= maybe (fail "the owner has no epoch to advance") pure

spec ∷ Spec
spec = describe "epochs" $ do
  it "invalidate every subscription once, discard what had not begun, tell the providers, and keep their accounting until they say they are done" $ bounded $ do
    fixture ← newIFixture
    fake ← newFakeEvents
    withBoundary $ \_ runtime → eventsFinish fake $ do
      owner ← ownerOf fixture fake runtime "epoch" [subscriber, holder] 4
      admitSubscriber fixture owner "i" "subscriber"
      subscribeTo' fixture owner "i" "a" "ticks"
      subscribeTo' fixture owner "i" "b" "state"
      holdOwner fixture owner
      deliverTo fake 0 Nothing 1 >>= (`shouldBe` EventAdmitted)
      deliverTo fake 0 Nothing 2 >>= (`shouldBe` EventAdmitted)
      deliverTo fake 1 Nothing 3 >>= (`shouldBe` EventAdmitted)
      report ← advance owner
      invalidatedSubscriptions (epochChange report) `shouldBe` 2
      -- What had not begun is gone with the epoch, counted by the model, and never runs.
      d ← subDiagnostics owner
      (sdLive d, sdDiscardedEvents d, sdInvalidated d) `shouldBe` (0, 3, 2)
      (snapshotQueued <$$> snapshotOf fixture owner "i") >>= (`shouldBe` Just 0)
      releaseOwner fixture
      -- The owner tells the providers, once each, at its next boundary.
      awaitCancelledSubs fake 2
      sync fixture owner "i" 1
      gotLines fixture >>= (`shouldBe` [])
      -- The accounting is retained, under the old identities, until the providers say they are done.
      (sdCharged <$> subDiagnostics owner) >>= (`shouldBe` 2)
      finishSubscription fake 0
      finishSubscription fake 1
      awaitSubDiagnostic owner ((== 0) . sdCharged)
      cancelledSubs fake >>= (`shouldBe` [0, 1])

  it "leaves the instance alone, and a producer holding an old feed cannot reach a subscription made after the change" $ bounded $ do
    fixture ← newIFixture
    fake ← newFakeEvents
    withBoundary $ \_ runtime → eventsFinish fake $ do
      owner ← ownerOf fixture fake runtime "new epoch" [subscriber] 4
      admitSubscriber fixture owner "i" "subscriber"
      subscribeTo' fixture owner "i" "a" "ticks"
      void (advance owner)
      -- The old handle names nothing now: unsubscribing it answers false, and tells nobody again.
      command fixture owner "i" "unsubscribe" "a"
      awaitLine fixture "cmd unsubscribe a false"
      phaseOf fixture owner "i" >>= (`shouldBe` Just Active)
      -- The same instance subscribes again, to the same endpoint, in the new epoch.
      subscribeTo' fixture owner "i" "b" "ticks"
      awaitSubscribed fake 2
      new ← ssInfo <$> subscribedAt fake 1
      old ← ssInfo <$> subscribedAt fake 0
      subscriptionNumber new `shouldSatisfy` (/= subscriptionNumber old)
      -- The old producer finds nothing; the new one is admitted.
      deliverTo fake 0 Nothing 1 >>= (`shouldBe` EventEnded)
      deliverTo fake 1 Nothing 2 >>= (`shouldBe` EventAdmitted)
      awaitLine fixture "got b n=2 seq=3 t=0"
      gotLines fixture >>= (`shouldBe` ["got b n=2 seq=3 t=0"])

  it "gives an unsubscribed subscription's number up for good: a feed made before it cannot reach one made after it" $ bounded $ do
    fixture ← newIFixture
    fake ← newFakeEvents
    withBoundary $ \_ runtime → eventsFinish fake $ do
      owner ← ownerOf fixture fake runtime "generations" [subscriber] 4
      admitSubscriber fixture owner "i" "subscriber"
      subscribeTo' fixture owner "i" "a" "ticks"
      command fixture owner "i" "unsubscribe" "a"
      awaitLine fixture "cmd unsubscribe a true"
      subscribeTo' fixture owner "i" "b" "ticks"
      deliverTo fake 0 Nothing 1 >>= (`shouldBe` EventEnded)
      deliverTo fake 1 Nothing 2 >>= (`shouldBe` EventAdmitted)
      awaitLine fixture "got b n=2 seq=3 t=0"

  it "cannot be used to reclaim a place by subscribing and unsubscribing over and over while the provider's retirement is pending" $ bounded $ do
    fixture ← newIFixture
    fake ← newFakeEvents
    withBoundary $ \_ runtime → eventsFinish fake $ do
      owner ← ownerOf fixture fake runtime "churn" [subscriber] 2
      admitSubscriber fixture owner "i" "subscriber"
      forM_ [("a", 0), ("b", 1)] $ \(key, index) → do
        subscribeTo' fixture owner "i" key "ticks"
        command fixture owner "i" "unsubscribe" key
        awaitLine fixture ("cmd unsubscribe " <> key <> " true")
        awaitCancelledSubs fake (index + 1)
      -- Neither is live, and the owner's two places are still held: the providers have proved nothing.
      d ← subDiagnostics owner
      (sdLive d, sdCharged d) `shouldBe` (0, 2)
      _ ← admitWith fixture owner "j" (subscriberRequest "j" "subscriber")
      awaitPhase fixture owner "j" Active
      commandWith fixture owner "j" "subscribe" "x" (Just "ticks") Nothing
      refusalOf fixture "j" >>= (`shouldSatisfy` maybe False (Text.isInfixOf "all 2 places are held"))
      subscribedCount fake >>= (`shouldBe` 2)
      -- One provider proves its retirement and its place is given back, and no sooner.
      finishSubscription fake 0
      awaitSubDiagnostic owner ((== 1) . sdCharged)
      admitSubscriber fixture owner "k" "subscriber"
      subscribeTo' fixture owner "k" "y" "ticks"
      awaitSubscribed fake 3

  it "lets an epoch's retirement outlast the change: the instance that ends afterwards waits for it" $ bounded $ do
    fixture ← newIFixture
    fake ← newFakeEvents
    withBoundary $ \_ runtime → eventsFinish fake $ do
      owner ← ownerOf fixture fake runtime "outlast" [subscriber] 4
      admitSubscriber fixture owner "i" "subscriber"
      subscribeTo' fixture owner "i" "a" "ticks"
      void (advance owner)
      awaitCancelledSubs fake 1
      void (settleControl fixture owner "i" InstanceStop)
      awaitLine fixture "shutdown stopped"
      -- Everything the instance does is done, and the provider has not proved the old subscription's
      -- retirement: the instance is not stopped.
      phaseOf fixture owner "i" >>= (`shouldBe` Just Stopping)
      finishSubscription fake 0
      settled ← awaitSettled fixture "i"
      resultPhase settled `shouldBe` Stopped

  it "tells a provider that interest was withdrawn while it was being handed the subscription, once, as soon as it has accepted it" $ bounded $ do
    fixture ← newIFixture
    fake ← newFakeEvents
    withBoundary $ \_ runtime → eventsFinish fake $ do
      owner ← ownerOf fixture fake runtime "mid handoff" [subscriber] 4
      -- The epoch changes while the provider is inside its subscribe: the subscription is invalidated
      -- before the engine holds the provider's work, which it must still be told to withdraw.
      onSubscribe fake (\_ → void (advanceRequestEpoch (scheduledEndpoint owner)))
      admitSubscriber fixture owner "i" "subscriber"
      subscribeTo' fixture owner "i" "a" "ticks"
      awaitCancelledSubs fake 1
      cancelledSubs fake >>= (`shouldBe` [0])
      d ← subDiagnostics owner
      (sdLive d, sdCharged d) `shouldBe` (0, 1)
      deliverTo fake 0 Nothing 1 >>= (`shouldBe` EventEnded)
      finishSubscription fake 0
      awaitSubDiagnostic owner ((== 0) . sdCharged)

  it "lets the invocation already selected for a delivery complete without entering Lua when the epoch changes before its callback begins" $ bounded $ do
    fixture ← newIFixture
    fake ← newFakeEvents
    withBoundary $ \_ runtime → eventsFinish fake $ do
      owner ← ownerOf fixture fake runtime "selected" [subscriber] 4
      admitSubscriber fixture owner "i" "subscriber"
      subscribeTo' fixture owner "i" "a" "ticks"
      writeIORef (sfObserver (ifBase fixture)) $ \context →
        when (contextName context == Just "i") (blockOn (ifBase fixture) "pending")
      deliverTo fake 0 Nothing 1 >>= (`shouldBe` EventAdmitted)
      awaitEntered (ifBase fixture) "pending"
      void (advance owner)
      writeIORef (sfObserver (ifBase fixture)) (const (pure ()))
      releaseGate (ifBase fixture) "pending"
      -- Nothing ran for it, and the instance is alive and serving: it takes a command all the same.
      sync fixture owner "i" 1
      gotLines fixture >>= (`shouldBe` [])
      phaseOf fixture owner "i" >>= (`shouldBe` Just Active)
      (snapshotQueued <$$> snapshotOf fixture owner "i") >>= (`shouldBe` Just 0)
      d ← subDiagnostics owner
      sdDiscardedEvents d `shouldBe` 1

  it "lets the VM go of the callbacks an epoch change ended, without the script unsubscribing them, while the instance goes on" $ bounded $ do
    fixture ← newIFixture
    fake ← newFakeEvents
    withBoundary $ \_ runtime → eventsFinish fake $ do
      owner ← ownerOf fixture fake runtime "collected" [subscriber] 4
      admitSubscriber fixture owner "i" "subscriber"
      forM_ [1 .. 3 ∷ Int] $ \cycle' → do
        let key = Text.pack ("t" <> show cycle')
        commandWith fixture owner "i" "subscribe_tracked" key (Just "ticks") Nothing
        awaitLine fixture ("cmd subscribe_tracked " <> key <> " ok")
        command fixture owner "i" "weak_count" key
        awaitLine fixture ("cmd weak_count " <> key <> " 1")
        void (advance owner)
        -- Nothing unsubscribed: the owner has the driver let go at its next boundary.
        command fixture owner "i" "weak_count" (key <> "after")
        awaitLine fixture ("cmd weak_count " <> key <> "after 0")
      phaseOf fixture owner "i" >>= (`shouldBe` Just Active)
      -- Each cycle's provider is told once and holds its place until it says it is done.
      awaitCancelledSubs fake 3
      (sdCharged <$> subDiagnostics owner) >>= (`shouldBe` 3)

  it "discards the events an owner on logical time held for ticks the old subscriptions were to be served at" $ bounded $ do
    fixture ← newIFixture
    fake ← newFakeEvents
    withBoundary $ \control runtime → eventsFinish fake $ do
      owner ←
        startSubscriber fixture runtime "logical epoch" [subscriber] subConfig (SettleAtAssignedTick Nothing) (subGrant fake 4 16) requiredPolicy
      admitSubscriber fixture owner "i" "subscriber"
      subscribeTo' fixture owner "i" "a" "ticks"
      deliverTo fake 0 (Just (DueSlot 2 0)) 1 >>= (`shouldBe` EventStaged)
      void (advance owner)
      d ← subDiagnostics owner
      (sdStaged d, sdDiscarded d) `shouldBe` (0, 1)
      -- The place is free again, and the tick passes without it.
      forM_ [1, 2 ∷ Int] (const (grantOne control owner))
      gotLines fixture >>= (`shouldBe` [])

infixl 4 <$$>
(<$$>) ∷ (a → b) → IO (Maybe a) → IO (Maybe b)
(<$$>) f action = fmap f <$> action
