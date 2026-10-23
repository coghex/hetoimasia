{-# LANGUAGE MagicHash #-}
{-# LANGUAGE UnboxedTuples #-}

-- | Owned subscriptions on an owner on elapsed time (LUA-26): a producer delivers from any thread
-- without blocking and never calls Lua; the owner looks up the live callback when it services a
-- delivery; overload is stated per endpoint (ordered events are refused and counted when the
-- queue has no place, replaceable state coalesces in place); a subscription ends once, whichever
-- path ends it; and deliveries to a paused instance are retained, in order.
module Test.LuaRuntime.Subscription.Basics (spec) where

import Control.Concurrent (forkIO)
import Control.Exception (evaluate)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Monad (forM, forM_, void, when)
import Data.List (elemIndex, sort)
import Data.Maybe (fromMaybe)
import Data.IORef (writeIORef)
import qualified Data.Text as Text
import Hetoimasia.Scripting.Lua.Instance
import Hetoimasia.Scripting.Lua.Owner (ModuleSource)
import Hetoimasia.Scripting.Lua.Provider
import Hetoimasia.Scripting.Lua.Runtime (LuaRuntime)
import Hetoimasia.Scripting.Lua.Scheduled
import Hetoimasia.Scripting.Lua.Value
import Data.Text (Text)
import qualified Data.Text.Array as Array
import GHC.Exts (Weak#, deRefWeak#, isTrue#, mkWeakNoFinalizer#)
import GHC.IO (IO (IO))
import qualified Data.Text.Internal as Internal
import System.Mem (performMajorGC)
import Test.Hspec (Spec, describe, it, shouldBe, shouldSatisfy)
import Test.LuaRuntime.Instance.Support
import Test.LuaRuntime.Request.Support (awaitLine, linesOf, refusalOf)
import Test.LuaRuntime.Scheduled.Support (SFixture (sfObserver), awaitEntered, blockOn, releaseGate)
import Test.LuaRuntime.Subscription.Support
import Test.LuaRuntime.Support (bounded, failExample, Gated (..), requiredPolicy, withBoundary, withBoundaryOpening)

-- | An owner of subscribers on elapsed time, granted both endpoints.
elapsedOwner ∷ IFixture → FakeEvents → LuaRuntime → Text → [ModuleSource] → IO ScheduledOwner
elapsedOwner fixture fake runtime label modules =
  startSubscriber fixture runtime label modules subConfig SettleOnArrival (subGrant fake 4 16) requiredPolicy

-- | Subscribe the instance of this name under this key to this endpoint, and wait until it has.
subscribeTo' ∷ IFixture → ScheduledOwner → Text → Text → Text → Maybe Text → IO ()
subscribeTo' fixture owner name key endpoint mode = do
  commandWith fixture owner name "subscribe" key (Just endpoint) mode
  awaitLine fixture ("cmd subscribe " <> key <> " ok")

-- | Run these on threads of their own and wait for every answer, in the order given.
onThreads ∷ [IO a] → IO [a]
onThreads actions = do
  boxes ← forM actions $ \action → do
    box ← newEmptyMVar
    _ ← forkIO (action >>= putMVar box)
    pure box
  mapM takeMVar boxes

spec ∷ Spec
spec = describe "on an owner on elapsed time" $ do
  describe "a producer" $ do
    it "delivers to the function a script subscribed, and the owner runs it" $ bounded $ do
      fixture ← newIFixture
      fake ← newFakeEvents
      withBoundary $ \_ runtime → eventsFinish fake $ do
        owner ← elapsedOwner fixture fake runtime "smoke" [subscriber]
        admitSubscriber fixture owner "i" "subscriber"
        subscribeTo' fixture owner "i" "a" "ticks" Nothing
        awaitSubscribed fake 1
        info <- ssInfo <$> subscribedAt fake 0
        subscriptionEndpoint info `shouldBe` "ticks"
        deliverTo fake 0 Nothing 7 >>= (`shouldBe` EventAdmitted)
        awaitLine fixture "got a n=7 seq=1 t=0"

    it "never blocks and never calls Lua, whatever the owner is doing, from threads of its own" $ bounded $ do
      fixture ← newIFixture
      fake ← newFakeEvents
      withBoundaryOpening [openAllGates fixture] $ \_ runtime → eventsFinish fake $ do
        owner ← elapsedOwner fixture fake runtime "producers" [subscriber, holder]
        admitSubscriber fixture owner "i" "subscriber"
        subscribeTo' fixture owner "i" "a" "ticks" Nothing
        -- The owner is held inside a callback of another instance: it runs nothing for this one.
        holdOwner fixture owner
        answers ← onThreads [deliverTo fake 0 Nothing n | n ← [1 .. 5]]
        answers `shouldBe` replicate 5 EventAdmitted
        -- Nothing ran: a producer's thread did not enter Lua, and the owner was away.
        gotLines fixture >>= (`shouldBe` [])
        (snapshotQueued <$$> snapshotOf fixture owner "i") >>= (`shouldBe` Just 5)
        releaseOwner fixture
        awaitGot fixture 5
        got ← gotLines fixture
        length got `shouldBe` 5
        -- They ran in the order admission gave them, whatever order the threads' arrivals took,
        -- and each exactly once.
        map (fieldOf "seq=") got `shouldBe` [1 .. 5]
        sort (map (fieldOf "n=") got) `shouldBe` [1 .. 5]

    it "is answered while a callback holds the owner inside Lua: a producer's thread does not enter it" $ bounded $ do
      fixture ← newIFixture
      fake ← newFakeEvents
      withBoundaryOpening [openAllGates fixture] $ \_ runtime → eventsFinish fake $ do
        owner ← elapsedOwner fixture fake runtime "owner thread" [subscriber]
        admitSubscriber fixture owner "i" "subscriber"
        subscribeTo' fixture owner "i" "a" "ticks" (Just "gate")
        -- The callback holds the owner at a gate while the producer's own thread answers.
        deliverTo fake 0 Nothing 1 >>= (`shouldBe` EventAdmitted)
        awaitEntered (ifBase fixture) "cb"
        deliverTo fake 0 Nothing 2 >>= (`shouldBe` EventAdmitted)
        releaseGate (ifBase fixture) "cb"
        awaitLine fixture "done a n=1"

  describe "ordered events" $ do
    it "run in the order they were delivered, each once" $ bounded $ do
      fixture ← newIFixture
      fake ← newFakeEvents
      withBoundaryOpening [openAllGates fixture] $ \_ runtime → eventsFinish fake $ do
        owner ← elapsedOwner fixture fake runtime "ordered" [subscriber, holder]
        admitSubscriber fixture owner "i" "subscriber"
        subscribeTo' fixture owner "i" "a" "ticks" Nothing
        holdOwner fixture owner
        forM_ [10, 20, 30] $ \n → deliverTo fake 0 Nothing n >>= (`shouldBe` EventAdmitted)
        releaseOwner fixture
        awaitLine fixture "got a n=30 seq=3 t=0"
        gotLines fixture >>= (`shouldBe` ["got a n=10 seq=1 t=0", "got a n=20 seq=2 t=0", "got a n=30 seq=3 t=0"])

    it "are refused and counted when the queue has no place, and nothing accepted is evicted" $ bounded $ do
      fixture ← newIFixture
      fake ← newFakeEvents
      withBoundaryOpening [openAllGates fixture] $ \_ runtime → eventsFinish fake $ do
        owner ← elapsedOwner fixture fake runtime "overflow" [subscriber, holder]
        admitSubscriber fixture owner "i" "subscriber"
        subscribeTo' fixture owner "i" "a" "ticks" Nothing
        holdOwner fixture owner
        -- The queue holds eight; the command that subscribed has run, so eight places are free.
        answers ← forM [1 .. 11] $ \n → deliverTo fake 0 Nothing n
        answers `shouldBe` replicate 8 EventAdmitted <> replicate 3 EventQueueFull
        d ← subDiagnostics owner
        (sdRefusedFull d, map readingRefused (sdSubscriptions d)) `shouldBe` (3, [3])
        (snapshotQueueFull <$$> snapshotOf fixture owner "i") >>= (`shouldBe` Just 3)
        releaseOwner fixture
        awaitLine fixture "got a n=8 seq=8 t=0"
        got ← gotLines fixture
        length got `shouldBe` 8
        take 1 got `shouldBe` ["got a n=1 seq=1 t=0"]

    it "surface a delivery failure the provider could not preserve: the instance fails with it and the application's policy decides" $ bounded $ do
      fixture ← newIFixture
      fake ← newFakeEvents
      withBoundary $ \_ runtime → eventsFinish fake $ do
        owner ← elapsedOwner fixture fake runtime "failure" [subscriber, holder]
        admitSubscriber fixture owner "i" "subscriber"
        admitSubscriber fixture owner "peer" "subscriber"
        subscribeTo' fixture owner "i" "a" "ticks" Nothing
        found ← subscribedAt fake 0
        -- The reason is a producer's, however long it is: the instance fails with a bounded copy of it.
        feedFail (ssFeed found) ("the producer's backlog was lost" <> Text.replicate 2000 "!")
        -- Its end withdraws interest in the subscription, and waits for the provider to prove it over.
        awaitCancelledSubs fake 1
        finishSubscription fake 0
        settled ← awaitSettled fixture "i"
        case resultOutcome settled of
          InstanceFailed failure → case failureError failure of
            ErrorDelivery endpoint why → do
              endpoint `shouldBe` "ticks"
              Text.length why `shouldBe` 512
              why `shouldSatisfy` Text.isPrefixOf "the producer's backlog was lost"
            other → failExample ("expected a delivery failure, found " <> show other)
          other → failExample ("expected the instance failed, found " <> show other)
        -- Its peer is isolated from it.
        phaseOf fixture owner "peer" >>= (`shouldBe` Just Active)
        d ← subDiagnostics owner
        sdFailures d `shouldBe` 1

  describe "replaceable state" $ do
    it "keeps one unstarted delivery, replaced in place by a later value, counted as coalesced" $ bounded $ do
      fixture ← newIFixture
      fake ← newFakeEvents
      withBoundaryOpening [openAllGates fixture] $ \_ runtime → eventsFinish fake $ do
        owner ← elapsedOwner fixture fake runtime "coalesce" [subscriber, holder]
        admitSubscriber fixture owner "i" "subscriber"
        subscribeTo' fixture owner "i" "a" "state" Nothing
        holdOwner fixture owner
        answers ← forM [1, 2, 3] $ \n → deliverTo fake 0 Nothing n
        answers `shouldBe` [EventAdmitted, EventCoalesced, EventCoalesced]
        (snapshotQueued <$$> snapshotOf fixture owner "i") >>= (`shouldBe` Just 1)
        releaseOwner fixture
        awaitLine fixture "got a n=3 seq=1 t=0"
        -- The values it replaced were counted and never delivered.
        gotLines fixture >>= (`shouldBe` ["got a n=3 seq=1 t=0"])
        d <- subDiagnostics owner
        (map readingCoalesced (sdSubscriptions d), sdCoalesced d) `shouldBe` ([2], 2)

    it "keeps the place of the delivery it replaces, among ordered events and other state" $ bounded $ do
      fixture ← newIFixture
      fake ← newFakeEvents
      withBoundaryOpening [openAllGates fixture] $ \_ runtime → eventsFinish fake $ do
        owner ← elapsedOwner fixture fake runtime "position" [subscriber, holder]
        admitSubscriber fixture owner "i" "subscriber"
        subscribeTo' fixture owner "i" "o" "ticks" Nothing
        subscribeTo' fixture owner "i" "s" "state" Nothing
        holdOwner fixture owner
        -- ordered 1, state 2, ordered 3, then state 4 replaces state 2 where it stood.
        _ ← deliverTo fake 0 Nothing 1
        _ ← deliverTo fake 1 Nothing 2
        _ ← deliverTo fake 0 Nothing 3
        deliverTo fake 1 Nothing 4 >>= (`shouldBe` EventCoalesced)
        releaseOwner fixture
        awaitLine fixture "got o n=3 seq=4 t=0"
        gotLines fixture >>= (`shouldBe` ["got o n=1 seq=2 t=0", "got s n=4 seq=3 t=0", "got o n=3 seq=4 t=0"])

    it "needs a place to fill an empty slot but none to replace what is unstarted, at capacity" $ bounded $ do
      fixture ← newIFixture
      fake ← newFakeEvents
      withBoundaryOpening [openAllGates fixture] $ \_ runtime → eventsFinish fake $ do
        owner ← elapsedOwner fixture fake runtime "capacity" [subscriber, holder]
        admitSubscriber fixture owner "i" "subscriber"
        subscribeTo' fixture owner "i" "o" "ticks" Nothing
        subscribeTo' fixture owner "i" "s" "state" Nothing
        holdOwner fixture owner
        -- Seven ordered events and the state's one delivery fill the queue.
        forM_ [1 .. 7] $ \n → deliverTo fake 0 Nothing n >>= (`shouldBe` EventAdmitted)
        deliverTo fake 1 Nothing 100 >>= (`shouldBe` EventAdmitted)
        -- Replacing what is unstarted takes no place, so it is not refused at capacity...
        deliverTo fake 1 Nothing 101 >>= (`shouldBe` EventCoalesced)
        -- ...and an ordered event, which needs one, is.
        deliverTo fake 0 Nothing 8 >>= (`shouldBe` EventQueueFull)
        releaseOwner fixture
        awaitLine fixture "got s n=101 seq=9 t=0"
        got ← gotLines fixture
        length got `shouldBe` 8

    it "needs a place of its own once the value it would replace has begun, and the callback's value is immutable" $ bounded $ do
      fixture ← newIFixture
      fake ← newFakeEvents
      withBoundaryOpening [openAllGates fixture] $ \_ runtime → eventsFinish fake $ do
        owner ← elapsedOwner fixture fake runtime "immutable" [subscriber]
        admitSubscriber fixture owner "i" "subscriber"
        subscribeTo' fixture owner "i" "a" "state" (Just "gate")
        deliverTo fake 0 Nothing 1 >>= (`shouldBe` EventAdmitted)
        awaitEntered (ifBase fixture) "cb"
        -- The callback has begun with 1 and is held inside it: a later value is a delivery of its
        -- own, behind it, and does not reach the one that began.
        deliverTo fake 0 Nothing 2 >>= (`shouldBe` EventAdmitted)
        releaseGate (ifBase fixture) "cb"
        awaitLine fixture "got a n=2 seq=2 t=0"
        gotLines fixture >>= (`shouldBe` ["got a n=1 seq=1 t=0", "got a n=2 seq=2 t=0"])
        d <- subDiagnostics owner
        map readingCoalesced (sdSubscriptions d) `shouldBe` [0]

    it "replaces the delivery already selected for the owner's next invocation, until its first segment runs" $ bounded $ do
      fixture ← newIFixture
      fake ← newFakeEvents
      withBoundaryOpening [openAllGates fixture] $ \_ runtime → eventsFinish fake $ do
        owner ← elapsedOwner fixture fake runtime "pending" [subscriber]
        admitSubscriber fixture owner "i" "subscriber"
        subscribeTo' fixture owner "i" "a" "state" Nothing
        -- From here the owner stops, on its own thread, just before the instance's next callback
        -- begins: the delivery has been selected and admitted as an invocation, and not begun.
        writeIORef (sfObserver (ifBase fixture)) $ \context →
          when (contextName context == Just "i") (blockOn (ifBase fixture) "pending")
        deliverTo fake 0 Nothing 1 >>= (`shouldBe` EventAdmitted)
        awaitEntered (ifBase fixture) "pending"
        deliverTo fake 0 Nothing 2 >>= (`shouldBe` EventCoalesced)
        writeIORef (sfObserver (ifBase fixture)) (const (pure ()))
        releaseGate (ifBase fixture) "pending"
        awaitLine fixture "got a n=2 seq=1 t=0"
        gotLines fixture >>= (`shouldBe` ["got a n=2 seq=1 t=0"])

  describe "unsubscribe" $ do
    it "settles once: the provider is told once, the unstarted deliveries are discarded and counted, and a delivery after it is refused" $ bounded $ do
      fixture ← newIFixture
      fake ← newFakeEvents
      withBoundaryOpening [openAllGates fixture] $ \_ runtime → eventsFinish fake $ do
        owner ← elapsedOwner fixture fake runtime "unsubscribe" [subscriber, holder]
        admitSubscriber fixture owner "i" "subscriber"
        subscribeTo' fixture owner "i" "a" "ticks" Nothing
        holdOwner fixture owner
        forM_ [1, 2, 3] $ \n → deliverTo fake 0 Nothing n >>= (`shouldBe` EventAdmitted)
        releaseOwner fixture
        -- Unsubscribed from a script, in the owner's order behind the deliveries.
        awaitLine fixture "got a n=3 seq=3 t=0"
        command fixture owner "i" "unsubscribe" "a"
        awaitLine fixture "cmd unsubscribe a true"
        command fixture owner "i" "unsubscribe" "a"
        awaitLine fixture "cmd unsubscribe a false"
        awaitCancelledSubs fake 1
        cancelledSubs fake >>= (`shouldBe` [0])
        deliverTo fake 0 Nothing 4 >>= (`shouldBe` EventEnded)
        d <- subDiagnostics owner
        (sdLive d, sdUnsubscribed d, sdRefusedEnded d) `shouldBe` (0, 1, 1)
        -- The provider has not proved its retirement: the place is still charged.
        sdCharged d `shouldBe` 1
        finishSubscription fake 0
        awaitSubDiagnostic owner ((== 0) . sdCharged)

    it "discards what was accepted and had not begun, counted by the model, and never runs it" $ bounded $ do
      fixture ← newIFixture
      fake ← newFakeEvents
      withBoundaryOpening [openAllGates fixture] $ \_ runtime → eventsFinish fake $ do
        owner ← elapsedOwner fixture fake runtime "discard" [subscriber, holder]
        admitSubscriber fixture owner "i" "subscriber"
        subscribeTo' fixture owner "i" "a" "ticks" Nothing
        holdOwner fixture owner
        -- The unsubscribe is queued ahead of the deliveries, so they are unstarted when it runs.
        command fixture owner "i" "unsubscribe" "a"
        forM_ [1, 2] $ \n → deliverTo fake 0 Nothing n >>= (`shouldBe` EventAdmitted)
        releaseOwner fixture
        awaitLine fixture "cmd unsubscribe a true"
        awaitSubDiagnostic owner ((== 2) . sdDiscardedEvents)
        sync fixture owner "i" 1
        gotLines fixture >>= (`shouldBe` [])
        (snapshotQueued <$$> snapshotOf fixture owner "i") >>= (`shouldBe` Just 0)

    it "settles once however a stop and an unsubscribe race, in either order" $ bounded $ do
      forM_ [True, False] $ \stopFirst → do
        fixture ← newIFixture
        fake ← newFakeEvents
        withBoundary $ \_ runtime → eventsFinish fake $ do
          owner ← elapsedOwner fixture fake runtime "race" [subscriber]
          admitSubscriber fixture owner "i" "subscriber"
          subscribeTo' fixture owner "i" "a" "ticks" Nothing
          if stopFirst
            then do
              void (settleControl fixture owner "i" InstanceStop)
              -- The instance has stopped: the command is refused, or never runs. Nothing else is an answer
              -- to it, and a failure of the example's own is not one.
              deliverCommand fixture owner "i" "unsubscribe" "a" Nothing Nothing
                >>= (`shouldSatisfy` \case DeliveryAccepted _ → True; DeliveryClosed → True; DeliveryUnknownTarget → True; _ → False)
            else do
              command fixture owner "i" "unsubscribe" "a"
              awaitLine fixture "cmd unsubscribe a true"
              void (settleControl fixture owner "i" InstanceStop)
          awaitCancelledSubs fake 1
          finishSubscription fake 0
          void (awaitSettled fixture "i")
          cancelledSubs fake >>= (`shouldBe` [0])
          d <- subDiagnostics owner
          (sdLive d, sdInvalidated d + sdUnsubscribed d) `shouldBe` (0, 1)

  describe "ending" $ do
    it "revokes the instance's subscriptions on every path that ends it, and the stop completes only when the provider proves its retirement" $ bounded $ do
      forM_ ["stop", "failure", "retire", "cancel"] $ \(path ∷ Text) → do
        fixture ← newIFixture
        fake ← newFakeEvents
        withBoundary $ \_ runtime → eventsFinish fake $ do
          owner ← elapsedOwner fixture fake runtime ("end " <> path) [subscriber]
          admitSubscriber fixture owner "i" "subscriber"
          subscribeTo' fixture owner "i" "a" "ticks" Nothing
          subscribeTo' fixture owner "i" "b" "state" Nothing
          case path of
            "stop" → void (settleControl fixture owner "i" InstanceStop)
            "failure" → do
              subscribeTo' fixture owner "i" "f" "ticks" (Just "fail")
              deliverTo fake 2 Nothing 1 >>= (`shouldBe` EventAdmitted)
            "retire" → retireScheduled owner
            _ → cancelScheduled owner
          awaitCancelledSubs fake (if path == "failure" then 3 else 2)
          -- Interest was withdrawn once for each; the provider has proved nothing.
          sort <$> cancelledSubs fake >>= (`shouldBe` [0 .. (if path == "failure" then 2 else 1)])
          d ← subDiagnostics owner
          sdLive d `shouldBe` 0
          forM_ [0 .. if path == "failure" then 2 else 1] (finishSubscription fake)
          awaitSubDiagnostic owner ((== 0) . sdCharged)
          -- A delivery to a subscription that ended is refused and counted, never run.
          deliverTo fake 0 Nothing 9 >>= (`shouldBe` EventEnded)

    it "waits for the provider's retirement before the instance is settled as stopped" $ bounded $ do
      fixture ← newIFixture
      fake ← newFakeEvents
      withBoundary $ \_ runtime → eventsFinish fake $ do
        owner ← elapsedOwner fixture fake runtime "stop waits" [subscriber]
        admitSubscriber fixture owner "i" "subscriber"
        subscribeTo' fixture owner "i" "a" "ticks" Nothing
        void (settleControl fixture owner "i" InstanceStop)
        awaitCancelledSubs fake 1
        -- Everything the instance does is done, and it is not stopped: the provider has not
        -- said its retirement is over.
        awaitLine fixture "shutdown stopped"
        phaseOf fixture owner "i" >>= (`shouldBe` Just Stopping)
        finishSubscription fake 0
        settled ← awaitSettled fixture "i"
        resultPhase settled `shouldBe` Stopped

    it "revokes the subscriptions of an instance that has no shutdown hook, without Lua's help" $ bounded $ do
      fixture ← newIFixture
      fake ← newFakeEvents
      withBoundary $ \_ runtime → eventsFinish fake $ do
        owner ← elapsedOwner fixture fake runtime "deaf" [deafSubscriber]
        admitSubscriber fixture owner "i" "deafsubscriber"
        awaitSubscribed fake 1
        void (settleControl fixture owner "i" InstanceStop)
        awaitCancelledSubs fake 1
        finishSubscription fake 0
        void (awaitSettled fixture "i")
        cancelledSubs fake >>= (`shouldBe` [0])

  describe "a subscription made in init" $ do
    it "belongs to the instance, not to the invocation: it survives that invocation and every callback after it" $ bounded $ do
      fixture ← newIFixture
      fake ← newFakeEvents
      withBoundary $ \_ runtime → eventsFinish fake $ do
        owner ← elapsedOwner fixture fake runtime "init" [initSubscriber]
        admitSubscriber fixture owner "i" "initsubscriber"
        awaitSubscribed fake 2
        awaitLine fixture "init subscribed"
        forM_ [1, 2, 3] $ \n → do
          deliverTo fake 0 Nothing n >>= (`shouldBe` EventAdmitted)
          awaitLine fixture (Text.pack ("got t n=" <> show n <> " seq=" <> show (n - 1 + 0) <> " t=0"))
        deliverTo fake 1 Nothing 40 >>= (`shouldBe` EventAdmitted)
        awaitLine fixture "got s n=40 seq=3 t=0"
        (sdLive <$> subDiagnostics owner) >>= (`shouldBe` 2)

    it "has a delivery accepted while init runs retained, and run after it" $ bounded $ do
      fixture ← newIFixture
      fake ← newFakeEvents
      -- The provider delivers as it is handed the subscription, which is inside init.
      onSubscribe fake $ \subscription →
        when (subscriptionEndpoint (subscriptionInfo subscription) == "ticks") $
          void (feedDeliver (subscriptionFeed subscription) Nothing (payloadOf 5))
      withBoundary $ \_ runtime → eventsFinish fake $ do
        owner ← elapsedOwner fixture fake runtime "early" [initSubscriber]
        admitSubscriber fixture owner "i" "initsubscriber"
        awaitLine fixture "got t n=5 seq=0 t=0"
        lines' ← linesOf fixture
        -- It ran after init had finished.
        lines' `shouldSatisfy` \recorded → indexOf "init subscribed" recorded < indexOf "got t n=5 seq=0 t=0" recorded

  describe "a delivery's measure" $ do
    -- What a callback is handed is the instance's number and the record, which the host checks
    -- together: a record that fits alone and does not fit with the number would be accepted and then
    -- fail the instance before its callback ran. A record is 108 bytes and five elements around its
    -- payload, and the instance's number is nine bytes and one element more.
    it "counts the instance's number with the record: the largest payload that fits is admitted and runs, and one more is refused" $ bounded $ do
      fixture ← newIFixture
      fake ← newFakeEvents
      withBoundary $ \_ runtime → eventsFinish fake $ do
        let wordy = (fakeEventEndpoint fake "text" OrderedEvents) {eventPayload = SText}
        owner ←
          startWith fixture runtime . withLimits (either (error . show) id (valueLimits 512 8 64)) $
            subscriptionSpec fixture "bytes" [subscriber] subConfig SettleOnArrival (SubscriptionGrant [wordy] 4 16) requiredPolicy
        _ ← admitWith fixture owner "i" (InstanceRequest (moduleNamed "subscriber") EventOnly (Just "i") OrdinaryClass ["cmd", "text"])
        awaitPhase fixture owner "i" Active
        commandWith fixture owner "i" "subscribe_size" "a" (Just "text") Nothing
        awaitLine fixture "cmd subscribe_size a ok"
        deliverRaw fake 0 Nothing (VText (Text.replicate (512 - 117) "x")) >>= (`shouldBe` EventAdmitted)
        awaitLine fixture "size a 395"
        deliverRaw fake 0 Nothing (VText (Text.replicate (512 - 116) "x")) >>= (`shouldBe` EventRefusedValue)
        phaseOf fixture owner "i" >>= (`shouldBe` Just Active)

    it "counts the instance's number among the elements too" $ bounded $ do
      fixture ← newIFixture
      fake ← newFakeEvents
      withBoundary $ \_ runtime → eventsFinish fake $ do
        let numbers = (fakeEventEndpoint fake "numbers" OrderedEvents) {eventPayload = SList SInteger}
        owner ←
          startWith fixture runtime . withLimits (either (error . show) id (valueLimits 4096 8 12)) $
            subscriptionSpec fixture "elements" [subscriber] subConfig SettleOnArrival (SubscriptionGrant [numbers] 4 16) requiredPolicy
        _ ← admitWith fixture owner "i" (InstanceRequest (moduleNamed "subscriber") EventOnly (Just "i") OrdinaryClass ["cmd", "numbers"])
        awaitPhase fixture owner "i" Active
        commandWith fixture owner "i" "subscribe_size" "a" (Just "numbers") Nothing
        awaitLine fixture "cmd subscribe_size a ok"
        deliverRaw fake 0 Nothing (VList (replicate 5 (VInteger 1))) >>= (`shouldBe` EventAdmitted)
        awaitLine fixture "size a 5"
        deliverRaw fake 0 Nothing (VList (replicate 6 (VInteger 1))) >>= (`shouldBe` EventRefusedValue)
        phaseOf fixture owner "i" >>= (`shouldBe` Just Active)

  describe "a retained delivery" $ do
    it "is a copy of its own: a small slice of a large buffer does not keep the buffer alive while the instance is paused" $ bounded $ do
      fixture ← newIFixture
      fake ← newFakeEvents
      withBoundary $ \_ runtime → eventsFinish fake $ do
        let wordy = (fakeEventEndpoint fake "text" OrderedEvents) {eventPayload = SText}
        owner ← startSubscriber fixture runtime "copy" [subscriber] subConfig SettleOnArrival (SubscriptionGrant [wordy] 4 16) requiredPolicy
        _ ← admitWith fixture owner "i" (InstanceRequest (moduleNamed "subscriber") EventOnly (Just "i") OrdinaryClass ["cmd", "text"])
        awaitPhase fixture owner "i" Active
        commandWith fixture owner "i" "subscribe_size" "a" (Just "text") Nothing
        awaitLine fixture "cmd subscribe_size a ok"
        void (settleControl fixture owner "i" InstancePause)
        weak ← deliverSliceOfLargeText fake
        performMajorGC
        -- The delivery waits in the paused instance's backlog, and the buffer it was sliced from is gone.
        (snapshotQueued <$$> snapshotOf fixture owner "i") >>= (`shouldBe` Just 1)
        bufferAlive weak >>= (`shouldBe` False)
        void (settleControl fixture owner "i" InstanceResume)
        awaitLine fixture "size a 5"

  describe "a refused subscribe" $ do
    it "quotes a script's endpoint name in the refusal in UTF-8 bytes, cut between characters" $ bounded $ do
      fixture ← newIFixture
      fake ← newFakeEvents
      withBoundary $ \_ runtime → eventsFinish fake $ do
        owner ←
          startSubscriber fixture runtime "refused name" [subscriber] subConfig SettleOnArrival (subGrant fake 1 16) requiredPolicy
        _ ← admitWith fixture owner "w" (InstanceRequest (moduleNamed "subscriber") EventOnly (Just "w") OrdinaryClass ["cmd", "ticks"])
        awaitPhase fixture owner "w" Active
        commandWith fixture owner "w" "subscribe" "a" (Just (Text.replicate 64 "😀")) Nothing
        -- 64 four-byte characters are 256 bytes: the refusal quotes the 16 that fit in 64 bytes.
        refusalOf fixture "w" >>= (`shouldSatisfy` maybe False (Text.isInfixOf ("no event endpoint named " <> Text.replicate 16 "😀" <> " is granted")))
    it "is a fault of the call: an endpoint the instance was not granted, one the owner does not offer, and a full owner" $ bounded $ do
      fixture ← newIFixture
      fake ← newFakeEvents
      withBoundary $ \_ runtime → eventsFinish fake $ do
        owner ←
          startSubscriber fixture runtime "refused" [subscriber] subConfig SettleOnArrival (subGrant fake 1 16) requiredPolicy
        let ask name granted endpoint = do
              _ ← admitWith fixture owner name (InstanceRequest (moduleNamed "subscriber") EventOnly (Just name) OrdinaryClass granted)
              awaitPhase fixture owner name Active
              commandWith fixture owner name "subscribe" "a" (Just endpoint) Nothing
        -- Granted the ticks endpoint only.
        ask "x" ["cmd", "ticks"] "state"
        refusalOf fixture "x" >>= (`shouldSatisfy` maybe False (Text.isInfixOf "no event endpoint named state is granted"))
        ask "y" ["cmd", "ticks", "nowhere"] "nowhere"
        refusalOf fixture "y" >>= (`shouldSatisfy` maybe False (Text.isInfixOf "no event endpoint named nowhere is granted"))
        -- The one place the owner has is taken by the first to subscribe.
        ask "a" ["cmd", "ticks"] "ticks"
        awaitLine fixture "cmd subscribe a ok"
        ask "b" ["cmd", "ticks"] "ticks"
        refusalOf fixture "b" >>= (`shouldSatisfy` maybe False (Text.isInfixOf "all 1 places are held"))
        -- Nothing was asked of the provider for any refused one.
        subscribedCount fake >>= (`shouldBe` 1)
        d ← subDiagnostics owner
        sdRefusedSubscribe d `shouldBe` 3

  describe "a paused instance" $ do
    it "retains the deliveries accepted while it was paused, in order, with their payloads and ticks, and runs them after it resumes" $ bounded $ do
      fixture ← newIFixture
      fake ← newFakeEvents
      withBoundary $ \_ runtime → eventsFinish fake $ do
        owner ← elapsedOwner fixture fake runtime "paused" [subscriber]
        admitSubscriber fixture owner "i" "subscriber"
        subscribeTo' fixture owner "i" "a" "ticks" Nothing
        void (settleControl fixture owner "i" InstancePause)
        forM_ [1, 2, 3] $ \n → deliverTo fake 0 Nothing n >>= (`shouldBe` EventAdmitted)
        (snapshotQueued <$$> snapshotOf fixture owner "i") >>= (`shouldBe` Just 3)
        gotLines fixture >>= (`shouldBe` [])
        void (settleControl fixture owner "i" InstanceResume)
        awaitLine fixture "got a n=3 seq=3 t=0"
        gotLines fixture >>= (`shouldBe` ["got a n=1 seq=1 t=0", "got a n=2 seq=2 t=0", "got a n=3 seq=3 t=0"])

-- | The number a @got@ line carries after this label.
fieldOf ∷ Text → Text → Int
fieldOf label line = read (Text.unpack (Text.takeWhile (/= ' ') (Text.drop (Text.length label) (snd (Text.breakOn label line)))))

-- | Where a line stands among those recorded; past the end if it is not there.
indexOf ∷ Text → [Text] → Int
indexOf wanted recorded = fromMaybe maxBound (elemIndex wanted recorded)

infixl 4 <$$>
(<$$>) ∷ (a → b) → IO (Maybe a) → IO (Maybe b)
(<$$>) f action = fmap f <$> action

-- | Deliver a five-character slice of a large text to the first subscription, and answer a weak
-- pointer to the large text's buffer, holding nothing of either: the buffer is alive only as long as
-- something that was kept still refers to it.
deliverSliceOfLargeText ∷ FakeEvents → IO BufferWeak
deliverSliceOfLargeText fake = do
  -- The size is not a constant, so the text is not one the program keeps for itself.
  size ← evaluate (1000000 + length (show (Text.length (Text.pack "a size"))))
  large ← evaluate (Text.replicate size "x")
  weak ← bufferWeak large
  deliverRaw fake 0 Nothing (VText (Text.take 5 large)) >>= (`shouldBe` EventAdmitted)
  pure weak

-- | A weak pointer to a text's buffer, which is shared by every slice of the text that was not copied.
data BufferWeak = BufferWeak (Weak# ())

bufferWeak ∷ Text → IO BufferWeak
bufferWeak (Internal.Text (Array.ByteArray buffer) _ _) =
  IO $ \s → case mkWeakNoFinalizer# buffer () s of
    (# s', weak #) → (# s', BufferWeak weak #)

-- | Whether the buffer is still alive.
bufferAlive ∷ BufferWeak → IO Bool
bufferAlive (BufferWeak weak) =
  IO $ \s → case deRefWeak# weak s of
    (# s', alive, _ #) → (# s', isTrue# alive #)
