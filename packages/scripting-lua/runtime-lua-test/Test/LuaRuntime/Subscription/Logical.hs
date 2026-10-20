-- | Provider events on an owner driven by logical time (D-36): the application assigns each event
-- the tick whose boundary admits it and its place among the events due then, and the owner admits
-- them at that boundary in the order of their places, never in arrival order. Overflow and
-- coalescing are decided there, so what a queue is full of and which value a callback sees follow
-- the logical sequence and not how fast the owner served; and the same inputs give the same
-- admissions and recorded effects however the producers' arrivals and the grants' pacing vary.
module Test.LuaRuntime.Subscription.Logical (spec) where

import Control.Monad (forM_, void)
import Data.List (permutations)
import Data.Text (Text)
import qualified Data.Text as Text
import Hetoimasia.Runtime.Supervision (RuntimeControl)
import Hetoimasia.Scripting.Lua.Instance
import Hetoimasia.Scripting.Lua.Owner (ModuleSource)
import Hetoimasia.Scripting.Lua.Provider
import Hetoimasia.Scripting.Lua.Runtime (LuaRuntime)
import Hetoimasia.Scripting.Lua.Scheduled
import Test.Hspec (Spec, describe, it, shouldBe)
import Test.LuaRuntime.Instance.Support
import Test.LuaRuntime.Request.Support (awaitLine, linesOf, tickReached)
import Test.LuaRuntime.Scheduled.Support (awaitEntered, releaseGate)
import Test.LuaRuntime.Subscription.Support
import Test.LuaRuntime.Support (Gated (..), bounded, requiredPolicy, withBoundary, withBoundaryOpening)

-- | An owner of subscribers on logical time, granted both endpoints with this room for held events.
logicalOwner ∷ IFixture → FakeEvents → LuaRuntime → Text → [ModuleSource] → Int → IO ScheduledOwner
logicalOwner fixture fake runtime label modules staging =
  startSubscriber fixture runtime label modules subConfig (SettleAtAssignedTick Nothing) (subGrant fake 4 staging) requiredPolicy

-- | Subscribe the instance of this name under this key to this endpoint, and wait until it has.
subscribeTo' ∷ IFixture → ScheduledOwner → Text → Text → Text → Maybe Text → IO ()
subscribeTo' fixture owner name key endpoint mode = do
  commandWith fixture owner name "subscribe" key (Just endpoint) mode
  awaitLine fixture ("cmd subscribe " <> key <> " ok")

-- | The place an event is assigned.
at ∷ Int → Int → Maybe DueSlot
at tick place = Just (DueSlot (fromIntegral tick) (fromIntegral place))

-- | Grant this many steps without waiting for any, and then wait for all of them.
stepsQueued ∷ RuntimeControl → ScheduledOwner → Int → IO ()
stepsQueued control owner count = do
  forM_ [1 .. count] (const (step owner))
  void (awaitTicksComplete control owner)

-- | The scenario the determinism examples vary: ordered events and replaceable state, assigned
-- places across three ticks. Answers what the callbacks were handed and the counters kept.
data Observed = Observed
  { seenGot ∷ [Text]
  , seenCoalesced ∷ Int
  , seenAdmitted ∷ [Int]
  , seenTick ∷ Int
  }
  deriving (Eq, Show)

-- | The deliveries of the scenario, as (endpoint index, tick, place, value).
scenario ∷ [(Int, Int, Int, Int)]
scenario =
  [ (0, 1, 0, 10)
  , (1, 1, 1, 11)
  , (1, 2, 0, 20)
  , (0, 2, 1, 21)
  , (1, 3, 0, 30)
  , (0, 3, 1, 31)
  ]

-- | Run the scenario with its deliveries in this order and the grants queued or served one by
-- one, with each callback taking this long on the injected clock.
observe ∷ [(Int, Int, Int, Int)] → Bool → IO Observed
observe order queued = do
  fixture ← newIFixture
  fake ← newFakeEvents
  withBoundary $ \control runtime → eventsFinish fake $ do
    owner ← logicalOwner fixture fake runtime "determinism" [subscriber] 16
    admitSubscriber fixture owner "i" "subscriber"
    subscribeTo' fixture owner "i" "o" "ticks" Nothing
    subscribeTo' fixture owner "i" "s" "state" Nothing
    forM_ order $ \(index, tick, place, value) →
      deliverTo fake index (at tick place) value >>= (`shouldBe` EventStaged)
    if queued
      then stepsQueued control owner 3
      else forM_ [1 .. 3 ∷ Int] (const (grantOne control owner))
    sync fixture owner "i" 1
    got ← gotLines fixture
    d ← subDiagnostics owner
    tick ← tickReached owner
    pure (Observed got (sdCoalesced d) (map readingAdmitted (sdSubscriptions d)) (fromIntegral tick))

spec ∷ Spec
spec = describe "on an owner on logical time" $ do
  describe "event admission" $ do
    it "admits events at the tick and place the application assigned, whatever order they arrived in" $ bounded $ do
      fixture ← newIFixture
      fake ← newFakeEvents
      withBoundary $ \control runtime → eventsFinish fake $ do
        owner ← logicalOwner fixture fake runtime "order" [subscriber] 16
        admitSubscriber fixture owner "i" "subscriber"
        subscribeTo' fixture owner "i" "a" "ticks" Nothing
        -- Arrival is the reverse of the assigned order.
        deliverTo fake 0 (at 2 0) 20 >>= (`shouldBe` EventStaged)
        deliverTo fake 0 (at 1 1) 11 >>= (`shouldBe` EventStaged)
        deliverTo fake 0 (at 1 0) 10 >>= (`shouldBe` EventStaged)
        -- Held, not admitted: nothing has run, and the instance has been handed nothing.
        gotLines fixture >>= (`shouldBe` [])
        (snapshotQueued <$$> snapshotOf fixture owner "i") >>= (`shouldBe` Just 0)
        stepsQueued control owner 2
        awaitGot fixture 3
        gotLines fixture >>= (`shouldBe` ["got a n=10 seq=1 t=1", "got a n=11 seq=2 t=1", "got a n=20 seq=3 t=2"])

    it "refuses a late assignment, a duplicate place, an unassigned event and a full store, and counts each" $ bounded $ do
      fixture ← newIFixture
      fake ← newFakeEvents
      withBoundary $ \control runtime → eventsFinish fake $ do
        owner ← logicalOwner fixture fake runtime "refusals" [subscriber] 2
        admitSubscriber fixture owner "i" "subscriber"
        subscribeTo' fixture owner "i" "a" "ticks" Nothing
        grantOne control owner
        -- Tick 1 has begun: it, and any before it, are late.
        deliverTo fake 0 (at 1 0) 1 >>= (`shouldBe` EventLate)
        deliverTo fake 0 (at 0 0) 1 >>= (`shouldBe` EventLate)
        deliverTo fake 0 (at 3 0) 3 >>= (`shouldBe` EventStaged)
        deliverTo fake 0 (at 3 0) 4 >>= (`shouldBe` EventDuplicate)
        -- An owner on logical time admits by an assigned place and never by arrival.
        deliverTo fake 0 Nothing 5 >>= (`shouldBe` EventUnassigned)
        deliverTo fake 0 (at 3 1) 6 >>= (`shouldBe` EventStaged)
        -- The store holds two.
        deliverTo fake 0 (at 4 0) 7 >>= (`shouldBe` EventStagingFull)
        d ← subDiagnostics owner
        (sdLate d, sdDuplicate d, sdUnassigned d, sdStagingFull d, sdStaged d, sdStagedTotal d) `shouldBe` (2, 1, 1, 1, 2, 2)

    it "refuses a place on an owner on elapsed time, which admits on arrival" $ bounded $ do
      fixture ← newIFixture
      fake ← newFakeEvents
      withBoundary $ \_ runtime → eventsFinish fake $ do
        owner ← startSubscriber fixture runtime "elapsed" [subscriber] subConfig SettleOnArrival (subGrant fake 4 16) requiredPolicy
        admitSubscriber fixture owner "i" "subscriber"
        subscribeTo' fixture owner "i" "a" "ticks" Nothing
        deliverTo fake 0 (at 1 0) 1 >>= (`shouldBe` EventNotLogical)
        deliverTo fake 0 Nothing 2 >>= (`shouldBe` EventAdmitted)
        (sdNotLogical <$> subDiagnostics owner) >>= (`shouldBe` 1)

    it "keeps the tick it was assigned on the delivery, however long it waited and whichever boundary served it" $ bounded $ do
      fixture ← newIFixture
      fake ← newFakeEvents
      withBoundary $ \control runtime → eventsFinish fake $ do
        owner ← logicalOwner fixture fake runtime "stamp" [subscriber] 16
        admitSubscriber fixture owner "i" "subscriber"
        subscribeTo' fixture owner "i" "a" "ticks" Nothing
        deliverTo fake 0 (at 4 0) 4 >>= (`shouldBe` EventStaged)
        stepsQueued control owner 6
        awaitGot fixture 1
        gotLines fixture >>= (`shouldBe` ["got a n=4 seq=1 t=4"])

  describe "replaceable state" $ do
    it "coalesces at the boundary of its tick: values assigned to one tick replace each other in the order of their places" $ bounded $ do
      fixture ← newIFixture
      fake ← newFakeEvents
      withBoundary $ \control runtime → eventsFinish fake $ do
        owner ← logicalOwner fixture fake runtime "same tick" [subscriber] 16
        admitSubscriber fixture owner "i" "subscriber"
        subscribeTo' fixture owner "i" "s" "state" Nothing
        -- Arrival is the reverse of the assigned order: the value of the later place wins.
        deliverTo fake 0 (at 1 2) 3 >>= (`shouldBe` EventStaged)
        deliverTo fake 0 (at 1 0) 1 >>= (`shouldBe` EventStaged)
        deliverTo fake 0 (at 1 1) 2 >>= (`shouldBe` EventStaged)
        grantOne control owner
        awaitGot fixture 1
        sync fixture owner "i" 1
        gotLines fixture >>= (`shouldBe` ["got s n=3 seq=1 t=1"])
        (sdCoalesced <$> subDiagnostics owner) >>= (`shouldBe` 2)

    it "never lets a value assigned to a later tick replace one visible at an earlier tick, even when it arrived first and the grants are queued" $ bounded $ do
      fixture ← newIFixture
      fake ← newFakeEvents
      withBoundary $ \control runtime → eventsFinish fake $ do
        owner ← logicalOwner fixture fake runtime "across ticks" [subscriber] 16
        admitSubscriber fixture owner "i" "subscriber"
        subscribeTo' fixture owner "i" "s" "state" Nothing
        deliverTo fake 0 (at 2 0) 2 >>= (`shouldBe` EventStaged)
        deliverTo fake 0 (at 1 0) 1 >>= (`shouldBe` EventStaged)
        -- Both ticks are granted before either can be served.
        stepsQueued control owner 2
        awaitGot fixture 2
        gotLines fixture >>= (`shouldBe` ["got s n=1 seq=1 t=1", "got s n=2 seq=2 t=2"])
        (sdCoalesced <$> subDiagnostics owner) >>= (`shouldBe` 0)

  describe "an instance that is stopping" $ do
    it "takes no event for a tick it will not reach: a delivery after its stop was applied is refused, not held, and takes no place in the store" $ bounded $ do
      fixture ← newIFixture
      fake ← newFakeEvents
      withBoundaryOpening [openAllGates fixture] $ \_ runtime → eventsFinish fake $ do
        owner ← logicalOwner fixture fake runtime "stopping" [gatedShutdownSubscriber] 2
        admitSubscriber fixture owner "i" "gatedshutdownsubscriber"
        subscribeTo' fixture owner "i" "a" "ticks" Nothing
        receipt ← expectControl fixture owner "i" InstanceStop
        -- The stop has been applied and the shutdown hook holds the owner: the instance has not ended.
        awaitEntered (ifBase fixture) "shutdown"
        deliverTo fake 0 (at 5 0) 1 >>= (`shouldBe` EventEnded)
        deliverTo fake 0 (at 5 1) 2 >>= (`shouldBe` EventEnded)
        d ← subDiagnostics owner
        (sdStaged d, sdRefusedEnded d, sdStagingFull d) `shouldBe` (0, 2, 0)
        releaseGate (ifBase fixture) "shutdown"
        _ ← waitInstanceControl receipt
        awaitCancelledSubs fake 1
        finishSubscription fake 0
        void (awaitSettled fixture "i")

  describe "an instance that ends" $ do
    it "has the events held for it discarded and counted, and the places they held given back" $ bounded $ do
      fixture ← newIFixture
      fake ← newFakeEvents
      withBoundary $ \control runtime → eventsFinish fake $ do
        owner ← logicalOwner fixture fake runtime "ends" [subscriber] 2
        admitSubscriber fixture owner "i" "subscriber"
        subscribeTo' fixture owner "i" "a" "ticks" Nothing
        deliverTo fake 0 (at 3 0) 1 >>= (`shouldBe` EventStaged)
        deliverTo fake 0 (at 3 1) 2 >>= (`shouldBe` EventStaged)
        deliverTo fake 0 (at 3 2) 3 >>= (`shouldBe` EventStagingFull)
        void (settleControl fixture owner "i" InstanceStop)
        awaitCancelledSubs fake 1
        d ← subDiagnostics owner
        (sdStaged d, sdDiscarded d) `shouldBe` (0, 2)
        finishSubscription fake 0
        void (awaitSettled fixture "i")
        -- The ticks pass, and the store has room again for another instance.
        forM_ [1 .. 3 ∷ Int] (const (grantOne control owner))
        gotLines fixture >>= (`shouldBe` [])

  describe "a due update" $ do
    it "does not overtake a delivery admitted before it fell due, and a later value coalesces into that delivery without moving it" $ bounded $ do
      fixture ← newIFixture
      fake ← newFakeEvents
      withBoundary $ \control runtime → eventsFinish fake $ do
        owner ← logicalOwner fixture fake runtime "update" [periodicSubscriber] 16
        _ ← admitWith fixture owner "i" (InstanceRequest (moduleNamed "periodicsubscriber") (Periodic (LogicalTicks 2)) (Just "i") OrdinaryClass ["cmd", "ticks", "state"])
        awaitPhase fixture owner "i" Active
        subscribeTo' fixture owner "i" "s" "state" Nothing
        -- Two values for the tick the update falls due at: the second replaces the first in place.
        deliverTo fake 0 (at 2 0) 1 >>= (`shouldBe` EventStaged)
        deliverTo fake 0 (at 2 1) 2 >>= (`shouldBe` EventStaged)
        stepsQueued control owner 2
        awaitLine fixture "update"
        recorded ← linesOf fixture
        -- The delivery ran, once, with the newest value, before the update that fell due behind it.
        filter (\line → line == "update" || Text.isPrefixOf "got " line) recorded `shouldBe` ["got s n=2 seq=1 t=2", "update"]

  describe "overflow" $ do
    it "is decided at the boundary, in the order of the places: an ordered event the queue has no place for fails the instance, and its peer is untouched" $ bounded $ do
      fixture ← newIFixture
      fake ← newFakeEvents
      withBoundary $ \control runtime → eventsFinish fake $ do
        owner ← logicalOwner fixture fake runtime "saturated" [subscriber] 16
        admitSubscriber fixture owner "i" "subscriber"
        admitSubscriber fixture owner "peer" "subscriber"
        subscribeTo' fixture owner "i" "a" "ticks" Nothing
        -- Ten events for one tick, eight places: the ninth and tenth are the ones refused, whichever
        -- order they arrived in and however fast the owner is.
        forM_ (reverse [0 .. 9]) $ \place → deliverTo fake 0 (at 1 place) (100 + place) >>= (`shouldBe` EventStaged)
        grantOne control owner
        awaitCancelledSubs fake 1
        finishSubscription fake 0
        settled ← awaitSettled fixture "i"
        case resultOutcome settled of
          InstanceFailed failure → case failureError failure of
            ErrorDelivery endpoint _ → endpoint `shouldBe` "ticks"
            other → fail ("expected a delivery failure, found " <> show other)
          other → fail ("expected the instance failed, found " <> show other)
        phaseOf fixture owner "peer" >>= (`shouldBe` Just Active)
        d ← subDiagnostics owner
        (sdRefusedFull d, sdFailures d) `shouldBe` (2, 1)

    it "refuses a fill of replaceable state the queue has no place for, counts it, and fails nothing" $ bounded $ do
      fixture ← newIFixture
      fake ← newFakeEvents
      withBoundary $ \control runtime → eventsFinish fake $ do
        owner ← logicalOwner fixture fake runtime "state full" [subscriber] 16
        admitSubscriber fixture owner "i" "subscriber"
        subscribeTo' fixture owner "i" "o" "ticks" (Just "wait")
        subscribeTo' fixture owner "i" "s" "state" Nothing
        -- Eight ordered events fill the queue, and a value of replaceable state for the same tick
        -- finds no place: it is refused and counted, and nothing fails, for only the newest value
        -- of a state matters and the next will replace it.
        forM_ [0 .. 7] $ \place → deliverTo fake 0 (at 1 place) (200 + place) >>= (`shouldBe` EventStaged)
        deliverTo fake 1 (at 1 8) 1 >>= (`shouldBe` EventStaged)
        grantOne control owner
        awaitGot fixture 1
        d ← subDiagnostics owner
        (sdRefusedFull d, sdFailures d, map readingRefused (sdSubscriptions d)) `shouldBe` (1, 0, [0, 1])
        phaseOf fixture owner "i" >>= (`shouldBe` Just Active)

  describe "granting" $ do
    it "gives the same admissions and effects whether the grants are served one by one or all queued" $ bounded $ do
      single ← observe scenario False
      queued ← observe scenario True
      queued `shouldBe` single
      -- Each tick's values were seen at that tick: nothing was replaced across ticks.
      seenCoalesced single `shouldBe` 0
      seenTick single `shouldBe` 3
      length (seenGot single) `shouldBe` 6

    it "gives the same admissions and effects however the producers' arrivals are ordered" $ bounded $ do
      reference ← observe scenario False
      forM_ (take 12 (permutations scenario)) $ \order → do
        observed ← observe order True
        observed `shouldBe` reference

  describe "a paused instance" $ do
    it "is admitted its events at their boundary and retains them in order, and its pause never holds a tick" $ bounded $ do
      fixture ← newIFixture
      fake ← newFakeEvents
      withBoundary $ \control runtime → eventsFinish fake $ do
        owner ← logicalOwner fixture fake runtime "paused" [subscriber] 16
        admitSubscriber fixture owner "i" "subscriber"
        subscribeTo' fixture owner "i" "a" "ticks" Nothing
        void (settleControl fixture owner "i" InstancePause)
        deliverTo fake 0 (at 1 1) 2 >>= (`shouldBe` EventStaged)
        deliverTo fake 0 (at 1 0) 1 >>= (`shouldBe` EventStaged)
        -- The tick begins and completes: nothing is waiting for events that cannot run.
        grantOne control owner
        tickReached owner >>= (`shouldBe` 1)
        gotLines fixture >>= (`shouldBe` [])
        (snapshotQueued <$$> snapshotOf fixture owner "i") >>= (`shouldBe` Just 2)
        void (settleControl fixture owner "i" InstanceResume)
        awaitGot fixture 2
        gotLines fixture >>= (`shouldBe` ["got a n=1 seq=1 t=1", "got a n=2 seq=2 t=1"])

  describe "the tick" $ do
    -- A started callback is the tick's claim for as long as it can run a segment: a callback that
    -- yields and then waits for a tick must wait for the same tick whether the grants behind its
    -- tick were queued or served one at a time.
    it "stays held while a started callback is still ready, so queued and individually served grants give the same effects" $ bounded $ do
      let run queued = do
            fixture ← newIFixture
            fake ← newFakeEvents
            withBoundary $ \control runtime → eventsFinish fake $ do
              owner ← logicalOwner fixture fake runtime "yielding" [subscriber] 16
              admitSubscriber fixture owner "i" "subscriber"
              subscribeTo' fixture owner "i" "a" "ticks" (Just "yieldwait")
              deliverTo fake 0 (at 1 0) 1 >>= (`shouldBe` EventStaged)
              if queued then stepsQueued control owner 2 else forM_ [1, 2 ∷ Int] (const (grantOne control owner))
              grantOne control owner
              awaitLine fixture "resumed a at 2"
              lines' ← linesOf fixture
              pure (filter (\line → Text.isPrefixOf "got " line || Text.isPrefixOf "yielded " line || Text.isPrefixOf "resumed " line) lines')
      queued ← run True
      single ← run False
      queued `shouldBe` single
      queued `shouldBe` ["got a n=1 seq=1 t=1", "yielded a", "resumed a at 2"]

    -- Several deliveries admitted at one tick, each suspended on a wait in turn: every one starts at the
    -- tick its predecessor ended at, however the grants behind them were queued.
    it "claims every tick that a delivery admitted at an earlier one can still run in, across suspensions" $ bounded $ do
      let run queued = do
            fixture ← newIFixture
            fake ← newFakeEvents
            withBoundary $ \control runtime → eventsFinish fake $ do
              owner ← logicalOwner fixture fake runtime "several" [subscriber] 16
              admitSubscriber fixture owner "i" "subscriber"
              subscribeTo' fixture owner "i" "a" "ticks" (Just "waitresume")
              forM_ [0 .. 2] $ \place → deliverTo fake 0 (at 1 place) (place + 1) >>= (`shouldBe` EventStaged)
              if queued then stepsQueued control owner 4 else forM_ [1 .. 4 ∷ Int] (const (grantOne control owner))
              awaitLine fixture "done a n=3 at 4"
              lines' ← linesOf fixture
              d ← subDiagnostics owner
              pure (filter (\line → Text.isPrefixOf "got " line || Text.isPrefixOf "done " line) lines', sdFailures d)
      queued ← run True
      single ← run False
      queued `shouldBe` single
      fst queued
        `shouldBe` [ "got a n=1 seq=1 t=1"
                   , "done a n=1 at 2"
                   , "got a n=2 seq=2 t=1"
                   , "done a n=2 at 3"
                   , "got a n=3 seq=3 t=1"
                   , "done a n=3 at 4"
                   ]

    it "does not wait for events behind an invocation that is suspended waiting for a tick" $ bounded $ do
      fixture ← newIFixture
      fake ← newFakeEvents
      withBoundary $ \control runtime → eventsFinish fake $ do
        owner ← logicalOwner fixture fake runtime "suspended" [subscriber] 16
        admitSubscriber fixture owner "i" "subscriber"
        subscribeTo' fixture owner "i" "a" "ticks" (Just "wait")
        deliverTo fake 0 (at 1 0) 1 >>= (`shouldBe` EventStaged)
        deliverTo fake 0 (at 1 1) 2 >>= (`shouldBe` EventStaged)
        grantOne control owner
        -- The first callback waits for the next tick and the second is behind it: the first tick
        -- completed all the same.
        awaitLine fixture "got a n=1 seq=1 t=1"
        tickReached owner >>= (`shouldBe` 1)
        grantOne control owner
        awaitLine fixture "done a n=1"
        awaitLine fixture "got a n=2 seq=2 t=1"
        grantOne control owner
        awaitLine fixture "done a n=2"

-- | Apply a function under the maybe of an action.
infixl 4 <$$>
(<$$>) ∷ (a → b) → IO (Maybe a) → IO (Maybe b)
(<$$>) f action = fmap f <$> action
