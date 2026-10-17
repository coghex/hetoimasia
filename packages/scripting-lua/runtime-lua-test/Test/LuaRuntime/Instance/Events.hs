-- | What delivering an event does: where it is held while an instance initializes
-- or is paused, how a full queue refuses, what a refusal answers, and what an
-- accepted event keeps.
module Test.LuaRuntime.Instance.Events (spec) where

import Control.Concurrent (forkIO)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Monad (forM, forM_, replicateM_)
import Data.List (sort)
import Data.Maybe (mapMaybe)
import qualified Data.Text as Text
import Hetoimasia.Scripting.Lua.Instance
import Hetoimasia.Scripting.Lua.Scheduled
import Hetoimasia.Scripting.Lua.Value (Value (VInteger, VText), valueLimits)
import Test.Hspec (Spec, describe, it, shouldBe, shouldSatisfy)
import Test.LuaRuntime.Instance.Support
import Test.LuaRuntime.Scheduled.Support (awaitEffect, awaitEntered, defaultSchedulerBounds, releaseGate)
import Test.LuaRuntime.Support (bounded, requiredPolicy, withBoundary)

spec ∷ Spec
spec = describe "events" $ do
  it "accepts an event while init runs, holds it until init has succeeded, and only then runs its callback" $ bounded $ do
    fixture ← newIFixture
    withBoundary $ \_ runtime → do
      owner ← startInstances fixture runtime "during init" [gateInit] (testConfig instanceBounds') requiredPolicy
      _ ← admit fixture owner "a" (moduleNamed "gateinit")
      awaitEntered (sf fixture) "init"
      phaseOf fixture owner "a" >>= (`shouldBe` Just Initializing)
      -- The connection was made before init returned, so the delivery is taken.
      deliverTick fixture owner "a" 1 >>= (`shouldBe` DeliveryAccepted 0)
      snapshotOf fixture owner "a" >>= (`shouldSatisfy` \held → fmap snapshotQueued held == Just 1)
      logged fixture >>= (`shouldBe` [])
      releaseGate (sf fixture) "init"
      awaitEffect (sf fixture) "tick 1 n=1"
      logged fixture >>= (`shouldBe` ["init done 1", "tick 1 n=1"])

  it "revokes the connection of an instance whose init fails and counts the events it held among the unstarted" $ bounded $ do
    fixture ← newIFixture
    withBoundary $ \_ runtime → do
      owner ← startInstances fixture runtime "failed init" [gateFail] (testConfig instanceBounds') requiredPolicy
      _ ← admit fixture owner "a" (moduleNamed "gatefail")
      awaitEntered (sf fixture) "init"
      forM_ [1, 2] (expectDelivered fixture owner "a")
      releaseGate (sf fixture) "init"
      settled ← awaitSettled fixture "a"
      resultPhase settled `shouldBe` Failed
      let termination = resultTermination settled
      terminationConnections termination `shouldBe` 1
      terminationUnstarted termination `shouldBe` 2
      logged fixture >>= (`shouldBe` [])
      deliverTick fixture owner "a" 3 >>= (`shouldBe` DeliveryUnknownTarget)

  it "refuses a delivery to a full queue explicitly, counts it and never evicts an accepted event" $ bounded $ do
    fixture ← newIFixture
    withBoundary $ \control runtime → do
      owner ← startInstances fixture runtime "overflow" [slow] (testConfig instanceBounds' {boundInvocationQueue = 2}) requiredPolicy
      _ ← admit fixture owner "a" (moduleNamed "slow")
      awaitPhase fixture owner "a" Active
      expectDelivered fixture owner "a" 1
      awaitDiagnosticsWaiting owner
      -- The first is running, suspended, so the queue holds the next two.
      forM_ [2, 3] (expectDelivered fixture owner "a")
      deliverTick fixture owner "a" 4 >>= (`shouldBe` DeliveryQueueFull)
      deliverTick fixture owner "a" 5 >>= (`shouldBe` DeliveryQueueFull)
      snapshotOf fixture owner "a" >>= (`shouldSatisfy` \held → fmap snapshotQueueFull held == Just 2)
      snapshotOf fixture owner "a" >>= (`shouldSatisfy` \held → fmap snapshotDelivered held == Just 3)
      -- Everything that was accepted runs, in order, and nothing else does.
      replicateM_ 3 (grantOne control owner)
      awaitEffect (sf fixture) "end 1 3"
      logged fixture
        >>= ( `shouldBe`
                [ "begin 1 1"
                , "end 1 1"
                , "begin 1 2"
                , "end 1 2"
                , "begin 1 3"
                , "end 1 3"
                ]
            )

  it "answers a delivery that cannot be taken: unknown, not connected, not a source, refused, closed" $ bounded $ do
    fixture ← newIFixture
    withBoundary $ \_ runtime → do
      owner ← startInstances fixture runtime "refusals" [echoer, noHooks, gateShutdown] (testConfig instanceBounds') requiredPolicy
      other ← startInstances fixture runtime "other" [echoer] (testConfig instanceBounds') requiredPolicy
      _ ← admit fixture owner "a" (moduleNamed "echoer")
      _ ← admit fixture owner "bare" (moduleNamed "nohooks")
      _ ← admit fixture owner "closing" (moduleNamed "gateshutdown")
      _ ← admit fixture other "elsewhere" (moduleNamed "echoer")
      awaitPhase fixture owner "a" Active
      awaitPhase fixture owner "bare" Active
      awaitPhase fixture owner "closing" Active
      a ← idOf fixture "a"
      let endpoint = scheduledEndpoint owner
          payload = tickEvent 1
      -- Another owner's identity, and an instance with no connection to the source.
      elsewhere ← idOf fixture "elsewhere"
      deliverEvent endpoint elsewhere "tick" payload >>= (`shouldBe` DeliveryUnknownTarget)
      deliverTick fixture owner "bare" 1 >>= (`shouldBe` DeliveryUnknownTarget)
      -- A name that is no source of this owner, and payloads that are not the source's.
      deliverEvent endpoint a "missing" payload >>= (`shouldBe` DeliveryUnknownTarget)
      deliverEvent endpoint a "tick" (VInteger 1) >>= (`shouldBe` DeliveryRefused)
      deliverEvent endpoint a "tick" (VText "tick") >>= (`shouldBe` DeliveryRefused)
      -- Nothing of that was kept.
      snapshotOf fixture owner "a" >>= (`shouldSatisfy` \held → fmap snapshotQueued held == Just 0)
      -- An owner that has begun to retire, with an instance still ending in its hook,
      -- takes nothing more.
      -- One of them is paused with two events held, so the end has something to discard.
      settleControl fixture owner "closing" InstancePause >>= (`shouldBe` ControlApplied)
      forM_ [1, 2] (expectDelivered fixture owner "closing")
      retireScheduled owner
      awaitEntered (sf fixture) "shutdown"
      deliverTick fixture owner "closing" 3 >>= (`shouldBe` DeliveryClosed)
      -- Ending closed its admission, revoked its connection and discarded what it held,
      -- at once, and not when the hook returned.
      snapshotOf fixture owner "closing"
        >>= (`shouldSatisfy` \held → fmap (\x → (snapshotPhase x, snapshotQueued x, snapshotConnections x)) held == Just (Stopping, 0, 0))
      releaseGate (sf fixture) "shutdown"

  it "refuses a payload whose event, stamped with its source and sequence, is over the owner's limits, rather than failing the instance when it runs" $ bounded $ do
    fixture ← newIFixture
    withBoundary $ \_ runtime → do
      -- The payload alone is twenty bytes; the record the callback is handed is more.
      limits ← either (fail . show) pure (valueLimits 90 8 4096)
      owner ←
        startWith fixture runtime . withLimits limits $
          instanceSpec fixture "limits" [echoer] (testConfig instanceBounds') requiredPolicy defaultSchedulerBounds
      _ ← admit fixture owner "a" (moduleNamed "echoer")
      awaitPhase fixture owner "a" Active
      deliverTick fixture owner "a" 1 >>= (`shouldBe` DeliveryRefused)
      phaseOf fixture owner "a" >>= (`shouldBe` Just Active)
      snapshotOf fixture owner "a" >>= (`shouldSatisfy` \held → fmap snapshotQueued held == Just 0)

  it "keeps an accepted event's sequence and the logical tick it was admitted at, however long it waits" $ bounded $ do
    fixture ← newIFixture
    withBoundary $ \control runtime → do
      owner ← startInstances fixture runtime "stamps" [echoer] (testConfig instanceBounds') requiredPolicy
      _ ← admit fixture owner "a" (moduleNamed "echoer")
      awaitPhase fixture owner "a" Active
      settleControl fixture owner "a" InstancePause >>= (`shouldBe` ControlApplied)
      grantOne control owner
      expectDelivered fixture owner "a" 1
      grantOne control owner
      -- A paused instance with nothing in flight starts nothing for an event it holds,
      -- and the owner has served a turn since.
      logged fixture >>= (`shouldBe` ["init 1"])
      snapshotOf fixture owner "a"
        >>= (`shouldSatisfy` \held → fmap (\x → (snapshotQueued x, snapshotExecution x)) held == Just (1, ExecIdle))
      grantOne control owner
      expectDelivered fixture owner "a" 2
      settleControl fixture owner "a" InstanceResume >>= (`shouldBe` ControlApplied)
      -- Resuming does not rewrite either as an event that has just happened.
      awaitEffect (sf fixture) "tick 1 n=2 seq=1 t=3 count=2"
      logged fixture
        >>= (`shouldBe` ["init 1", "tick 1 n=1 seq=0 t=1 count=1", "tick 1 n=2 seq=1 t=3 count=2"])

  it "takes events from many producer threads without blocking, each with a sequence of its own" $ bounded $ do
    fixture ← newIFixture
    withBoundary $ \_ runtime → do
      owner ← startInstances fixture runtime "producers" [echoer] (testConfig instanceBounds' {boundInvocationQueue = 64}) requiredPolicy
      _ ← admit fixture owner "a" (moduleNamed "echoer")
      awaitPhase fixture owner "a" Active
      identity ← idOf fixture "a"
      let endpoint = scheduledEndpoint owner
      done ← forM [1 .. 4 ∷ Int] $ \producer → do
        finished ← newEmptyMVar
        _ ← forkIO $ do
          answers ← forM [1 .. 5 ∷ Int] $ \n → deliverEvent endpoint identity "tick" (tickEvent (producer * 10 + n))
          putMVar finished answers
        pure finished
      answers ← concat <$> forM done takeMVar
      let sequences = mapMaybe (\case DeliveryAccepted n → Just n; _ → Nothing) answers
      sort sequences `shouldBe` [0 .. 19]
      awaitCount fixture 21
      -- They ran in the order they were accepted: the sequence each callback was
      -- handed, in the order they ran, is the sequence admission gave.
      entries ← logged fixture
      let ticks = drop 1 entries
      length ticks `shouldBe` 20
      forM_ (zip [0 ∷ Int ..] ticks) $ \(index, entry) →
        entry `shouldSatisfy` Text.isInfixOf (" seq=" <> Text.pack (show index) <> " ")
