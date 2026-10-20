-- | How the runner hands an event to the subscriptions: whom, in what order, in what place, and what it
-- does with every answer, against feeds that answer as the example says.
module Test.LuaRuntime.Runner.Production (spec) where

import Control.Concurrent (forkIO, killThread)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar, tryReadMVar)
import Control.Concurrent.STM (atomically, retry)
import Control.Exception (try)
import Control.Monad (forM, forM_)
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import Data.List (sortOn)
import Data.Word (Word64)
import Hetoimasia.Scripting.Lua.Instance (InstanceId (instanceOwner))
import Hetoimasia.Scripting.Lua.Provider
  ( DueSlot (DueSlot)
  , EventAnswer (..)
  , EventEndpoint (eventName, eventSubscribe)
  , EventFeed (EventFeed)
  , EventSubscription (EventSubscription)
  , ProviderWork (workCancel, workRetirement)
  , RetirementState (ProviderComplete, ProviderFailed, ProviderPending)
  , SubscriptionInfo (SubscriptionInfo)
  )
import Hetoimasia.Scripting.Lua.Runner
import Hetoimasia.Scripting.Lua.Runner.Internal
import Test.Hspec (Spec, describe, it, shouldBe, shouldReturn, shouldSatisfy)
import Test.LuaRuntime.Runner.Support
import Test.LuaRuntime.Support (bounded, failExample, withBoundary)

-- | A real instance's identity, which a subscription needs: from a run of one script.
anInstanceId ∷ IO InstanceId
anInstanceId = do
  fixture ← newRFixture
  withScripts [("one.lua", lua ["function run(self) end"])] $ \paths →
    withBoundary $ \_ runtime → do
      _ ← run fixture runtime (config fixture [noWait (scriptAt paths 0)]) >>= expectRan
      (_, admitted) ← admittedOf fixture
      case admitted of
        (identity, _) : _ → pure identity
        [] → failExample "no instance was admitted"

-- | A subscription of the endpoint, as the engine hands it over, whose feed answers this way and notes
-- every delivery.
subscribed ∷ Registry → InstanceId → Word64 → (Maybe DueSlot → EventAnswer) → IO (IORef [(Maybe DueSlot, Word64)], ProviderWork)
subscribed registry identity number answer = do
  seen ← newIORef []
  work ←
    eventSubscribe (instancesEndpoint registry) $
      EventSubscription
        (EventFeed (\slot _ → atomicModifyIORef' seen (\held → ((slot, number) : held, ())) >> pure (answer slot)) (\_ → pure ()))
        (SubscriptionInfo (instanceOwner identity) identity "instances" number)
  pure (seen, work)

startedOf ∷ InstanceId → InstanceEvent
startedOf identity = InstanceEvent True identity (Just "x.lua") Nothing

endedOf ∷ InstanceId → InstanceEvent
endedOf identity = InstanceEvent False identity (Just "x.lua") (Just "completed")

spec ∷ Spec
spec = describe "producing events" $ do
  it "names the endpoint the scripts subscribe to" $ bounded $ do
    registry ← newRegistry
    eventName (instancesEndpoint registry) `shouldBe` runnerEventsName

  it "delivers each event once to every subscription, in ascending order of their numbers, whatever order they arrived in" $ bounded $ do
    identity ← anInstanceId
    registry ← newRegistry
    order ← newIORef []
    forM_ [30, 10, 20] $ \number → do
      (seen, _) ← subscribed registry identity number (const EventStaged)
      atomicModifyIORef' order (\held → (held <> [seen], ()))
    produceEvents registry (PlaceAt (Just 5)) [startedOf identity, endedOf identity]
    feeds ← readIORef order
    perFeed ← forM feeds readIORef
    -- Each subscription was handed each event once.
    map length perFeed `shouldBe` [2, 2, 2]
    tally ← tallyOf registry
    -- Three subscriptions, two events: six attempts, the two kinds of event counted apart from them.
    (tallyStarted tally, tallyEnded tally, tallyAttempts tally, tallyStaged tally) `shouldBe` (1, 1, 6, 6)
    -- The order of delivery is the order of the numbers: every delivery's sequence, taken in the order of the
    -- numbers, is increasing within one event.
    let bySequence = concat [[(sequenceNumber, number) | (Just (DueSlot _ sequenceNumber), number) ← deliveries] | deliveries ← perFeed]
    map snd (sortOn fst bySequence) `shouldBe` [10, 20, 30, 10, 20, 30]

  it "gives every delivery on a tick VM a place of its own: the tick it was given, and a sequence that increases in production order and then recipient order" $ bounded $ do
    identity ← anInstanceId
    registry ← newRegistry
    everything ← newIORef []
    forM_ [3, 1, 2] $ \number → do
      (seen, _) ← subscribed registry identity number (const EventStaged)
      -- Every feed notes into its own list; the order across them is read from the sequences.
      atomicModifyIORef' everything (\held → (held <> [seen], ()))
    produceEvents registry (PlaceAt (Just 7)) [startedOf identity, endedOf identity]
    feeds ← readIORef everything
    deliveries ← concat <$> forM feeds readIORef
    let slots = sortOn fst [(sequenceNumber, (tick, number)) | (Just (DueSlot tick sequenceNumber), number) ← deliveries]
    -- Six deliveries, each with a slot at tick 7 and no two sharing a sequence, taken in order of sequence:
    -- the first event to recipients 1, 2, 3, then the second.
    length slots `shouldBe` 6
    map (fst . snd) slots `shouldBe` replicate 6 7
    map (snd . snd) slots `shouldBe` [1, 2, 3, 1, 2, 3]
    let sequences = map fst slots
    sequences `shouldSatisfy` (\xs → and (zipWith (<) xs (drop 1 xs)))

  it "delivers on arrival, with no place, on an elapsed VM" $ bounded $ do
    identity ← anInstanceId
    registry ← newRegistry
    (seen, _) ← subscribed registry identity 1 (const EventAdmitted)
    produceEvents registry (PlaceAt Nothing) [startedOf identity]
    readIORef seen >>= (`shouldBe` [(Nothing, 1)])

  describe "counts every answer as what it is" $ do
    let counted answer expected = it ("counts " <> show answer) $ bounded $ do
          identity ← anInstanceId
          registry ← newRegistry
          _ ← subscribed registry identity 1 (const answer)
          produceEvents registry (PlaceAt (Just 1)) [startedOf identity]
          tally ← tallyOf registry
          expected tally `shouldBe` True
    counted EventAdmitted (\t → tallyAdmitted t == 1 && tallyAttempts t == 1)
    counted EventStaged (\t → tallyStaged t == 1 && tallyAttempts t == 1)
    counted EventQueueFull (\t → tallyQueueFull t == 1 && tallyAttempts t == 1)
    counted EventStagingFull (\t → tallyStagingFull t == 1 && tallyAttempts t == 1)
    counted EventEnded (\t → tallySubscriptionEnded t == 1 && tallyAttempts t == 1)

  describe "raises every answer that is a defect as a failure of the host, and counts it as an attempt" $
    forM_ [EventCoalesced, EventRefusedValue, EventLate, EventDuplicate, EventUnassigned, EventNotLogical] $ \answer →
      it ("raises " <> show answer) $ bounded $ do
        identity ← anInstanceId
        registry ← newRegistry
        _ ← subscribed registry identity 1 (const answer)
        result ← try (produceEvents registry (PlaceAt (Just 1)) [startedOf identity])
        result `shouldBe` Left (EventDefect answer)
        tallyAttempts <$> tallyOf registry `shouldReturn` 1

  describe "the subscriptions the engine hands over" $
    it "forgets a subscription when the engine withdraws interest, and proves its retirement at once" $ bounded $ do
      identity ← anInstanceId
      registry ← newRegistry
      (seen, work) ← subscribed registry identity 1 (const EventAdmitted)
      state ← atomically (workRetirement work)
      isComplete state `shouldBe` True
      workCancel work
      produceEvents registry (PlaceAt Nothing) [startedOf identity]
      -- Nothing is delivered to it after, and nothing waits on the runner.
      readIORef seen `shouldReturn` []
      tallyAttempts <$> tallyOf registry `shouldReturn` 0

  describe "the gate the owner parks at while an instance is admitted" $ do
    let parkedNow gate = atomically (gateParked gate)
        awaitParked gate wanted = atomically (gateParked gate >>= \now → if now == wanted then pure () else retry)
        waiter gate = do
          done ← newEmptyMVar
          thread ← forkIO (gateWait gate >> putMVar done ())
          pure (done, thread)
    it "lets the owner through at once while it is not held" $ bounded $ do
      gate ← newGate
      gateWait gate
      parkedNow gate `shouldReturn` False
    it "parks the owner where the runner can see it, until the gate is opened, and then no longer" $ bounded $ do
      gate ← newGate
      atomically (holdGate gate)
      (done, _) ← waiter gate
      awaitParked gate True
      tryReadMVar done `shouldReturn` Nothing
      atomically (freeGate gate)
      takeMVar done
      parkedNow gate `shouldReturn` False
      -- Opened for good: a later segment passes.
      gateWait gate
    it "lets one segment through for one permit, however often it is given while the owner is on its way, and parks it again" $ bounded $ do
      gate ← newGate
      atomically (holdGate gate)
      (done, _) ← waiter gate
      awaitParked gate True
      -- Both asks in one transaction, so the owner cannot take the permit between them.
      (first, second) ← atomically ((,) <$> permitOne gate <*> permitOne gate)
      (first, second) `shouldBe` (True, False)
      takeMVar done
      awaitParked gate False
      (again, _) ← waiter gate
      awaitParked gate True
      tryReadMVar again `shouldReturn` Nothing
      atomically (freeGate gate)
      takeMVar again
    it "no longer reads as parked when the parked owner is cancelled" $ bounded $ do
      gate ← newGate
      atomically (holdGate gate)
      (_, thread) ← waiter gate
      awaitParked gate True
      killThread thread
      awaitParked gate False
  where
    isComplete = \case
      ProviderComplete → True
      ProviderPending → False
      ProviderFailed _ → False
