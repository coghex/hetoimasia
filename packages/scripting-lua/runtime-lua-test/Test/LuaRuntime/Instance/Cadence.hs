-- | Periodic updates on a logical cadence (LUA-24): the interval an instance is
-- admitted with and how it converts, when an update falls due and the @dt@ it is
-- handed, what a cadence point does while an invocation is active, how an update
-- shares the instance's queue, and what a tick waits for.
--
-- Every example runs real instances on a real supervised scheduled owner. Time is
-- granted by hand, a stated number of nanoseconds at a time, and an example knows
-- what has happened by what the hooks recorded and by the owner's own state, never by
-- waiting for a while.
module Test.LuaRuntime.Instance.Cadence (spec) where

import Control.Concurrent.STM (atomically, retry)
import Control.Exception (SomeException, finally, fromException, try)
import Control.Monad (forM_, replicateM_, void)
import Data.Foldable (toList)
import Data.IORef (writeIORef)
import Data.List (elemIndex)
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Word (Word64)
import Hetoimasia.Foundation.Time (maximumDuration, zeroDuration)
import Hetoimasia.Runtime.Supervision (RuntimeControl)
import Hetoimasia.Scripting.Lua.Instance
import Hetoimasia.Scripting.Lua.Owner
import Hetoimasia.Scripting.Lua.Scheduled
import Test.Hspec (Spec, describe, it, shouldBe, shouldSatisfy)
import Test.LuaRuntime.Instance.Support
import Test.LuaRuntime.Scheduled.Support (SFixture (sfDelay), awaitDiagnostics, awaitEffect, awaitEntered, awaitIdle, defaultSchedulerBounds, releaseGate)
import Test.LuaRuntime.Scheduler.Support (nanoseconds)
import Test.LuaRuntime.Support (bounded, requiredPolicy, withBoundary)

-- The modules -------------------------------------------------------------------

-- | A periodic instance: each update records the @dt@ it was handed, each event the
-- number it carries.
ticker ∷ ModuleSource
ticker =
  hooksModule
    "ticker"
    [ "function init(self, api)"
    , "  api.connect('tick', function(self, event) " <> record <> "('event ' .. event.payload.n) end)"
    , "end"
    , "function update(self, dt) " <> record <> "('update ' .. dt) end"
    , "function shutdown(self, reason) " <> record <> "('shutdown ' .. reason) end"
    ]

-- | An update that waits five ticks. It records the @dt@ it began with, and the tick
-- it reached and the duration its wait was granted, as a binding granted to the script
-- (@fx.resume@) tells it.
longUpdate ∷ ModuleSource
longUpdate =
  hooksModule
    "longupdate"
    [ "function update(self, dt)"
    , "  " <> record <> "('update ' .. dt .. ' begin')"
    , "  sched.wait_ticks(5)"
    , "  local kind, tick, granted = fx.resume()"
    , "  " <> record <> "('update ' .. dt .. ' end tick=' .. tick .. ' waited=' .. granted)"
    , "end"
    ]

-- | The same, whose segments cost time on the injected clock.
pacedUpdate ∷ ModuleSource
pacedUpdate =
  hooksModule
    "pacedupdate"
    [ "function update(self, dt)"
    , "  fx.delay()"
    , "  " <> record <> "('update ' .. dt .. ' begin')"
    , "  sched.wait_ticks(5)"
    , "  fx.delay()"
    , "  local kind, tick, granted = fx.resume()"
    , "  " <> record <> "('update ' .. dt .. ' end tick=' .. tick .. ' waited=' .. granted)"
    , "end"
    ]

-- | An event callback that waits five ticks, and an update.
callbackWaiter ∷ ModuleSource
callbackWaiter =
  hooksModule
    "callbackwaiter"
    [ "function init(self, api)"
    , "  api.connect('tick', function(self, event)"
    , "    " <> record <> "('callback ' .. event.payload.n .. ' begin')"
    , "    sched.wait_ticks(5)"
    , "    local kind, tick, granted = fx.resume()"
    , "    " <> record <> "('callback ' .. event.payload.n .. ' end tick=' .. tick .. ' waited=' .. granted)"
    , "  end)"
    , "end"
    , "function update(self, dt) " <> record <> "('update ' .. dt) end"
    ]

-- | An event callback that waits one tick, and an update.
slowTicker ∷ ModuleSource
slowTicker =
  hooksModule
    "slowticker"
    [ "function init(self, api)"
    , "  api.connect('tick', function(self, event)"
    , "    " <> record <> "('callback ' .. event.payload.n .. ' begin')"
    , "    sched.wait_ticks(1)"
    , "    " <> record <> "('callback ' .. event.payload.n .. ' end')"
    , "  end)"
    , "end"
    , "function update(self, dt) " <> record <> "('update ' .. dt) end"
    ]

-- | A callback that waits two ticks and then holds the owner at a gate, so that what an
-- example does meanwhile is accepted before the owner serves any of it.
gatedWaiter ∷ ModuleSource
gatedWaiter =
  hooksModule
    "gatedwaiter"
    [ "function init(self, api)"
    , "  api.connect('tick', function(self, event)"
    , "    sched.wait_ticks(2)"
    , "    " <> record <> "('gated reached')"
    , "    fx.block('hold')"
    , "    " <> record <> "('gated released')"
    , "  end)"
    , "end"
    ]

-- | An event callback that holds the owner at a gate, for the first event only, and an
-- update.
gatedTicker ∷ ModuleSource
gatedTicker =
  hooksModule
    "gatedticker"
    [ "function init(self, api)"
    , "  api.connect('tick', function(self, event)"
    , "    " <> record <> "('event ' .. event.payload.n .. ' begin')"
    , "    if event.payload.n == 1 then fx.block('gate') end"
    , "    " <> record <> "('event ' .. event.payload.n .. ' end')"
    , "  end)"
    , "end"
    , "function update(self, dt) " <> record <> "('update ' .. dt) end"
    ]

-- | No update at all.
noUpdate ∷ ModuleSource
noUpdate = hooksModule "noupdate" ["function init(self, api) end"]

-- Driving -------------------------------------------------------------------------

-- | Admit a periodic instance of the module of this name, granted the @tick@ source.
periodic ∷ IFixture → ScheduledOwner → Text → Interval → IO InstanceTicket
periodic fixture owner name interval =
  admitWith fixture owner name (InstanceRequest (moduleNamed name) (Periodic interval) (Just name) OrdinaryClass ["tick"])

-- | Grant a step of each of these many nanoseconds, and wait for each tick to complete
-- before the next is granted.
grantEach ∷ RuntimeControl → ScheduledOwner → [Word64] → IO ()
grantEach control owner steps = forM_ steps $ \step → do
  _ ← grantScheduledStep (scheduledEndpoint owner) (nanoseconds step)
  void (awaitTicksComplete control owner)

-- | Accept a step without waiting for it.
grantNow ∷ ScheduledOwner → Word64 → IO ()
grantNow owner step = void (grantScheduledStep (scheduledEndpoint owner) (nanoseconds step))

-- | An owner of these modules with the standard bounds and the @tick@ source, and the
-- hooks' effects; the examples' common start.
withOwner ∷ [ModuleSource] → InstanceConfig → (IFixture → RuntimeControl → ScheduledOwner → IO a) → IO a
withOwner modules config body = do
  fixture ← newIFixture
  withBoundary $ \control runtime → do
    owner ← startInstances fixture runtime "cadence" modules config requiredPolicy
    body fixture control owner

-- | The same, for an example that holds the owner at a gate: the gates are opened
-- whatever the example does, so a failure of it fails instead of waiting on an owner
-- that is held.
withGatedOwner ∷ [ModuleSource] → InstanceConfig → (IFixture → RuntimeControl → ScheduledOwner → IO a) → IO a
withGatedOwner modules config body =
  withOwner modules config $ \fixture control owner →
    body fixture control owner `finally` (releaseGate (sf fixture) "hold" >> releaseGate (sf fixture) "gate")

-- | Block until the instance of this name has a due update, or none.
awaitUpdateOwed ∷ IFixture → ScheduledOwner → Text → Bool → IO ()
awaitUpdateOwed fixture owner name wanted = do
  identity ← idOf fixture name
  atomically $
    inspectInstance (scheduledEndpoint owner) identity >>= \case
      Just snapshot | snapshotUpdateOwed snapshot == wanted → pure ()
      _ → retry

-- | Whether the instance of this name has an update owed.
updateOwed' ∷ IFixture → ScheduledOwner → Text → IO Bool
updateOwed' fixture owner name = maybe False snapshotUpdateOwed <$> snapshotOf fixture owner name

-- | Wait for the n-th wait the scheduler has taken.
awaitWaits ∷ ScheduledOwner → Int → IO ()
awaitWaits owner n = awaitDiagnostics owner (\counts → diagWaiting counts >= n)

spec ∷ Spec
spec = describe "logical cadence" $ do
  conversionSpec
  admissionSpec
  updateSpec
  overlapSpec
  queueSpec
  pauseSpec
  settlementSpec
  arithmeticSpec
  determinismSpec

-- Conversion ------------------------------------------------------------------------

conversionSpec ∷ Spec
conversionSpec = describe "an interval" $ do
  let tick = Just (nanoseconds 10)
  it "converts a number of ticks as it is, with or without a tick duration" $ do
    resolveInterval tick (LogicalTicks 3) `shouldBe` Right (CadenceTicks 3)
    resolveInterval Nothing (LogicalTicks 3) `shouldBe` Right (CadenceTicks 3)
    resolveInterval Nothing (LogicalTicks (fromIntegral (maxBound ∷ Word64))) `shouldBe` Right (CadenceTicks maxBound)
  it "converts a duration only when it is an exact multiple of the tick duration, and refuses it, naming it, otherwise" $ do
    resolveInterval tick (LogicalDuration (nanoseconds 30)) `shouldBe` Right (CadenceTicks 3)
    resolveInterval tick (LogicalDuration (nanoseconds 10)) `shouldBe` Right (CadenceTicks 1)
    let unequal = LogicalDuration (nanoseconds 35)
    resolveInterval tick unequal `shouldBe` Left (IntervalNotExact unequal (nanoseconds 10))
    resolveInterval tick (LogicalDuration (nanoseconds 9)) `shouldBe` Left (IntervalNotExact (LogicalDuration (nanoseconds 9)) (nanoseconds 10))
    resolveInterval Nothing (LogicalDuration (nanoseconds 30)) `shouldBe` Left (IntervalNoTickDuration (LogicalDuration (nanoseconds 30)))
  it "refuses a zero, a negative and an unrepresentable interval, naming it, and rounds nothing" $ do
    resolveInterval tick (LogicalTicks 0) `shouldBe` Left (IntervalNotPositive (LogicalTicks 0))
    resolveInterval tick (LogicalTicks (-5)) `shouldBe` Left (IntervalNotPositive (LogicalTicks (-5)))
    let large = LogicalTicks (fromIntegral (maxBound ∷ Word64) + 1)
    resolveInterval tick large `shouldBe` Left (IntervalUnrepresentable large)
    resolveInterval tick (LogicalDuration zeroDuration) `shouldBe` Left (IntervalNotPositive (LogicalDuration zeroDuration))
    resolveInterval tick (ElapsedEvery zeroDuration) `shouldBe` Left (IntervalNotPositive (ElapsedEvery zeroDuration))
  it "keeps an elapsed interval as the positive duration it is, not needing a tick duration" $ do
    resolveInterval Nothing (ElapsedEvery (nanoseconds 7)) `shouldBe` Right (CadenceElapsed (nanoseconds 7))
    resolveInterval tick (ElapsedEvery (nanoseconds 7)) `shouldBe` Right (CadenceElapsed (nanoseconds 7))

-- Admission -------------------------------------------------------------------------

admissionSpec ∷ Spec
admissionSpec = describe "admitting a periodic instance" $ do
  let config = (testConfig instanceBounds') {instanceTickDuration = Just (nanoseconds 2)}
  it "refuses an interval that does not convert, naming it, taking no place and no result, and admits one that does" $ bounded $
    withOwner [ticker] config $ \fixture control owner → do
      let request interval = InstanceRequest (moduleNamed "ticker") (Periodic interval) (Just "t") OrdinaryClass ["tick"]
          admitted = admitInstance (scheduledEndpoint owner)
      admitted (request (LogicalDuration (nanoseconds 5))) >>= (`shouldSatisfy` \case InstanceIntervalRefused (IntervalNotExact _ _) → True; _ → False)
      admitted (request (LogicalTicks 0)) >>= (`shouldSatisfy` \case InstanceIntervalRefused (IntervalNotPositive _) → True; _ → False)
      atomically (inspectInstances (scheduledEndpoint owner)) >>= (`shouldBe` [])
      -- Six nanoseconds is three of this owner's two-nanosecond ticks.
      _ ← admitWith fixture owner "t" (request (LogicalDuration (nanoseconds 6)))
      awaitPhase fixture owner "t" Active
      grantEach control owner [1, 1]
      logged fixture >>= (`shouldBe` [])
      grantEach control owner [4]
      logged fixture >>= (`shouldBe` ["update 6"])
  it "refuses a duration for an owner given no tick duration, while a number of ticks needs none" $ bounded $
    withOwner [ticker] (testConfig instanceBounds') $ \fixture _ owner → do
      admitInstance (scheduledEndpoint owner) (InstanceRequest (moduleNamed "ticker") (Periodic (LogicalDuration (nanoseconds 4))) Nothing OrdinaryClass [])
        >>= (`shouldSatisfy` \case InstanceIntervalRefused (IntervalNoTickDuration _) → True; _ → False)
      _ ← periodic fixture owner "ticker" (LogicalTicks 4)
      awaitPhase fixture owner "ticker" Active
  it "refuses an owner configured with a zero tick duration, before anything starts" $ bounded $ do
    fixture ← newIFixture
    withBoundary $ \_ runtime → do
      outcome ← try @SomeException (startInstances fixture runtime "zero" [ticker] (testConfig instanceBounds') {instanceTickDuration = Just zeroDuration} requiredPolicy)
      case outcome of
        Left failure → fmap (\(InstancesRefused violations) → toList violations) (fromException failure) `shouldBe` Just [TickDurationNotPositive]
        Right _ → fail "the configuration should have been refused"
  it "fails a periodic instance whose module defines no update before any hook runs, naming it" $ bounded $
    withOwner [noUpdate] (testConfig instanceBounds') $ \fixture _ owner → do
      _ ← periodic fixture owner "noupdate" (LogicalTicks 2)
      settled ← awaitSettled fixture "noupdate"
      resultPhase settled `shouldBe` Failed
      fmap failureMessage (failureOf' settled) `shouldSatisfy` maybe False (Text.isInfixOf "update")

-- Updates ---------------------------------------------------------------------------

updateSpec ∷ Spec
updateSpec = describe "a logical update" $ do
  it "falls due one interval after init, handed the duration granted since, and again after each finishes, awaited by the tick it falls in" $ bounded $
    withOwner [ticker] (testConfig instanceBounds') $ \fixture control owner → do
      _ ← periodic fixture owner "ticker" (LogicalTicks 3)
      awaitPhase fixture owner "ticker" Active
      grantEach control owner [10, 20]
      logged fixture >>= (`shouldBe` [])
      -- Nothing is awaited for: the tick that made the update due did not complete until it had run.
      grantEach control owner [30]
      logged fixture >>= (`shouldBe` ["update 60"])
      grantEach control owner [1, 2, 3]
      logged fixture >>= (`shouldBe` ["update 60", "update 6"])
      snapshotOf fixture owner "ticker" >>= (`shouldSatisfy` maybe False (not . snapshotUpdateOwed))
  it "keeps the duration granted across a wait inside the update, and reports the wait's own duration to a binding granted to the script" $ bounded $
    withOwner [longUpdate] (testConfig instanceBounds') $ \fixture control owner → do
      _ ← admitWith fixture owner "longupdate" (InstanceRequest (moduleNamed "longupdate") (Periodic (LogicalTicks 2)) (Just "u") OrdinaryClass [])
      awaitPhase fixture owner "longupdate" Active
      grantEach control owner [1]
      grantEach control owner [1]
      logged fixture >>= (`shouldBe` ["update 2 begin"])
      awaitWaits owner 1
      -- The points at ticks 4 and 6 pass while the update waits, adding nothing.
      grantEach control owner [1, 1, 1, 1]
      logged fixture >>= (`shouldBe` ["update 2 begin"])
      grantEach control owner [1]
      -- Its own dt is what it began with; the wait's duration is the binding's to tell.
      logged fixture >>= (`shouldBe` ["update 2 begin", "update 2 end tick=7 waited=5"])
      -- The next update is due at the first point after it finished, handed what was granted since.
      grantEach control owner [1]
      logged fixture >>= (`shouldBe` ["update 2 begin", "update 2 end tick=7 waited=5", "update 1 begin"])

-- Overlap ---------------------------------------------------------------------------

overlapSpec ∷ Spec
overlapSpec = describe "a cadence point passed during an active invocation" $ do
  it "adds nothing when an event callback waits across it: the ticks complete, the next update is due at the first point after the callback finishes, and the duration is what was granted since" $ bounded $
    withOwner [callbackWaiter] (testConfig instanceBounds') $ \fixture control owner → do
      _ ← periodic fixture owner "callbackwaiter" (LogicalTicks 2)
      awaitPhase fixture owner "callbackwaiter" Active
      expectDelivered fixture owner "callbackwaiter" 1
      awaitWaits owner 1
      -- Ticks 1 to 5, with the points at 2 and 4 passing: none deadlocks and no update runs.
      grantEach control owner [1, 1, 1, 1]
      logged fixture >>= (`shouldBe` ["callback 1 begin"])
      grantEach control owner [1]
      logged fixture >>= (`shouldBe` ["callback 1 begin", "callback 1 end tick=5 waited=5"])
      -- The first update after it is at tick 6, and is handed all six granted since init;
      -- the callback's wait was five.
      grantEach control owner [1]
      logged fixture >>= (`shouldBe` ["callback 1 begin", "callback 1 end tick=5 waited=5", "update 6"])
      -- No backlog of updates for the points it passed: one more at the next point.
      grantEach control owner [1, 1]
      logged fixture >>= (`shouldBe` ["callback 1 begin", "callback 1 end tick=5 waited=5", "update 6", "update 2"])
  it "takes grants accepted ahead of their application at the state of the application: producer arrival decides nothing" $ bounded $
    withOwner [callbackWaiter] (testConfig instanceBounds') $ \fixture control owner → do
      _ ← periodic fixture owner "callbackwaiter" (LogicalTicks 2)
      awaitPhase fixture owner "callbackwaiter" Active
      expectDelivered fixture owner "callbackwaiter" 1
      awaitWaits owner 1
      -- Four are accepted together, and applied one at a time as each completes.
      replicateM_ 4 (grantNow owner 1)
      void (awaitTicksComplete control owner)
      logged fixture >>= (`shouldBe` ["callback 1 begin"])
      grantEach control owner [1, 1]
      logged fixture >>= (`shouldBe` ["callback 1 begin", "callback 1 end tick=5 waited=5", "update 6"])
  it "keeps the queued events in order behind the active callback, and the next update at the first point after the last of them" $ bounded $
    withOwner [callbackWaiter] (testConfig instanceBounds') $ \fixture control owner → do
      _ ← periodic fixture owner "callbackwaiter" (LogicalTicks 2)
      awaitPhase fixture owner "callbackwaiter" Active
      expectDelivered fixture owner "callbackwaiter" 1
      awaitWaits owner 1
      expectDelivered fixture owner "callbackwaiter" 2
      grantEach control owner [1, 1, 1, 1, 1]
      -- The second callback begins as the first ends, and the points at 6, 8 and 10 pass
      -- while it waits, the last being the grant that resumes it.
      awaitWaits owner 2
      grantEach control owner [1, 1, 1, 1, 1]
      logged fixture
        >>= ( `shouldBe`
                ["callback 1 begin", "callback 1 end tick=5 waited=5", "callback 2 begin", "callback 2 end tick=10 waited=5"]
            )
      grantEach control owner [1, 1]
      logged fixture
        >>= ( `shouldBe`
                ["callback 1 begin", "callback 1 end tick=5 waited=5", "callback 2 begin", "callback 2 end tick=10 waited=5", "update 12"]
            )

-- Queue -----------------------------------------------------------------------------

queueSpec ∷ Spec
queueSpec = describe "a due update in the instance's queue" $ do
  it "queued behind an event that begins and waits releases its tick, keeps its place, and runs after the event, with one pending" $ bounded $
    withGatedOwner [slowTicker, holder] (testConfig instanceBounds') $ \fixture control owner → do
      _ ← periodic fixture owner "slowticker" (LogicalTicks 2)
      awaitPhase fixture owner "slowticker" Active
      holdOwner fixture owner
      expectDelivered fixture owner "slowticker" 1
      grantNow owner 1
      grantNow owner 1
      releaseOwner fixture
      awaitEffect (sf fixture) "callback 1 begin"
      awaitWaits owner 1
      -- Tick 2 completes though the update has not run, which waits behind the callback.
      void (awaitTicksComplete control owner)
      logged fixture >>= (`shouldBe` ["callback 1 begin"])
      updateOwed' fixture owner "slowticker" >>= (`shouldBe` True)
      -- More points while it waits behind a callback that has begun add nothing.
      grantEach control owner [1]
      awaitEffect (sf fixture) "update 3"
      logged fixture >>= (`shouldBe` ["callback 1 begin", "callback 1 end", "update 3"])
      updateOwed' fixture owner "slowticker" >>= (`shouldBe` False)
  it "keeps a continuous producer behind a due update: the events accepted before it fell due run first, those accepted after it run after it" $ bounded $
    withGatedOwner [gatedTicker, holder] (testConfig instanceBounds') $ \fixture control owner → do
      _ ← periodic fixture owner "gatedticker" (LogicalTicks 2)
      awaitPhase fixture owner "gatedticker" Active
      holdOwner fixture owner
      forM_ [1, 2] (expectDelivered fixture owner "gatedticker")
      grantNow owner 1
      grantNow owner 1
      releaseOwner fixture
      -- The first event has begun and holds the owner; the update fell due behind both.
      awaitEntered (sf fixture) "gate"
      awaitUpdateOwed fixture owner "gatedticker" True
      forM_ [3, 4] (expectDelivered fixture owner "gatedticker")
      releaseGate (sf fixture) "gate"
      awaitEffect (sf fixture) "event 4 end"
      void (awaitTicksComplete control owner)
      logged fixture
        >>= ( `shouldBe`
                [ "event 1 begin"
                , "event 1 end"
                , "event 2 begin"
                , "event 2 end"
                , "update 2"
                , "event 3 begin"
                , "event 3 end"
                , "event 4 begin"
                , "event 4 end"
                ]
            )
  it "is retained when the event queue is full, refusing later events without moving the update, and is never a second update" $ bounded $
    withGatedOwner [gatedTicker, holder] (testConfig instanceBounds') $ \fixture control owner → do
      _ ← periodic fixture owner "gatedticker" (LogicalTicks 2)
      awaitPhase fixture owner "gatedticker" Active
      holdOwner fixture owner
      forM_ [1 .. 8] (expectDelivered fixture owner "gatedticker")
      deliverTick fixture owner "gatedticker" 9 >>= (`shouldBe` DeliveryQueueFull)
      grantNow owner 1
      grantNow owner 1
      releaseOwner fixture
      awaitEntered (sf fixture) "gate"
      awaitUpdateOwed fixture owner "gatedticker" True
      -- The first event has begun and holds no place, so one more fits, and then the queue
      -- is full again: the update competes for none of it, and stays owed in its place.
      deliverTick fixture owner "gatedticker" 10 >>= (`shouldSatisfy` \case DeliveryAccepted _ → True; _ → False)
      deliverTick fixture owner "gatedticker" 11 >>= (`shouldBe` DeliveryQueueFull)
      updateOwed' fixture owner "gatedticker" >>= (`shouldBe` True)
      grantNow owner 1
      grantNow owner 1
      releaseGate (sf fixture) "gate"
      awaitEffect (sf fixture) "event 10 end"
      awaitUpdateOwed fixture owner "gatedticker" False
      void (awaitTicksComplete control owner)
      awaitEffect (sf fixture) "update 2"
      void (awaitTicksComplete control owner)
      final ← logged fixture
      -- The tick the update fell due in did not complete until it had run, after the last
      -- of the events accepted before it, and ahead of the one accepted after it. Only
      -- then were the two ticks granted meanwhile applied, and the second update is the
      -- point at the fourth: one update at a time, never a backlog.
      let position wanted = elemIndex wanted final
          updates = [index | (index, entry) ← zip [0 ∷ Int ..] final, Text.isPrefixOf "update " entry]
      case updates of
        [first, second] → do
          (Just first > position "event 8 end", Just first < position "event 10 begin") `shouldBe` (True, True)
          Just second > position "event 10 end" `shouldBe` True
        _ → fail ("expected two updates, found " <> show updates)
      filter (Text.isPrefixOf "update ") final `shouldBe` ["update 2", "update 2"]

-- Pause -----------------------------------------------------------------------------

pauseSpec ∷ Spec
pauseSpec = describe "pausing" $ do
  it "accrues no periodic demand while paused, and the first update newly due is one full interval after the resume" $ bounded $
    withOwner [ticker] (testConfig instanceBounds') $ \fixture control owner → do
      _ ← periodic fixture owner "ticker" (LogicalTicks 2)
      awaitPhase fixture owner "ticker" Active
      grantEach control owner [1]
      settleControl fixture owner "ticker" InstancePause >>= (`shouldBe` ControlApplied)
      -- The point at tick 2 and the ones after it find the instance paused.
      grantEach control owner [1, 1, 1, 1]
      logged fixture >>= (`shouldBe` [])
      settleControl fixture owner "ticker" InstanceResume >>= (`shouldBe` ControlApplied)
      -- Resumed at tick 5: the first update is at tick 7, not 6; every tick granted is
      -- accounted, the paused ones included.
      grantEach control owner [1]
      logged fixture >>= (`shouldBe` [])
      grantEach control owner [1]
      logged fixture >>= (`shouldBe` ["update 7"])
  it "lets the tick complete when a due update is paused before it starts, retains it, and runs it after the resume" $ bounded $
    withGatedOwner [ticker, gatedWaiter] (testConfig instanceBounds') $ \fixture control owner → do
      _ ← periodic fixture owner "ticker" (LogicalTicks 2)
      _ ← admit fixture owner "gatedwaiter" (moduleNamed "gatedwaiter")
      awaitPhase fixture owner "ticker" Active
      awaitPhase fixture owner "gatedwaiter" Active
      expectDelivered fixture owner "gatedwaiter" 1
      awaitWaits owner 1
      grantEach control owner [1]
      -- Tick 2 wakes the other instance's callback, which holds the owner at its gate,
      -- and makes the update due behind it, admitted and not begun.
      grantNow owner 1
      awaitEntered (sf fixture) "hold"
      receipt ← expectControl fixture owner "ticker" InstancePause
      releaseGate (sf fixture) "hold"
      void (awaitTicksComplete control owner)
      waitInstanceControl receipt >>= (`shouldBe` ControlApplied)
      logged fixture >>= (`shouldBe` ["gated reached", "gated released"])
      updateOwed' fixture owner "ticker" >>= (`shouldBe` True)
      -- Resumed, it runs, handed what was granted since init, and the cadence goes on.
      settleControl fixture owner "ticker" InstanceResume >>= (`shouldBe` ControlApplied)
      awaitEffect (sf fixture) "update 2"
      grantEach control owner [1, 1]
      awaitEffect (sf fixture) "update 2"
      length . filter (== "update 2") <$> logged fixture >>= (`shouldBe` 2)
  it "discards a due update that a stop reaches before it starts, counts it, and lets the tick complete" $ bounded $
    withGatedOwner [ticker, gatedWaiter] (testConfig instanceBounds') $ \fixture control owner → do
      _ ← periodic fixture owner "ticker" (LogicalTicks 2)
      _ ← admit fixture owner "gatedwaiter" (moduleNamed "gatedwaiter")
      awaitPhase fixture owner "ticker" Active
      awaitPhase fixture owner "gatedwaiter" Active
      expectDelivered fixture owner "gatedwaiter" 1
      awaitWaits owner 1
      grantEach control owner [1]
      grantNow owner 1
      awaitEntered (sf fixture) "hold"
      receipt ← expectControl fixture owner "ticker" InstanceStop
      releaseGate (sf fixture) "hold"
      void (awaitTicksComplete control owner)
      waitInstanceControl receipt >>= (`shouldBe` ControlApplied)
      settled ← awaitSettled fixture "ticker"
      resultPhase settled `shouldBe` Stopped
      terminationUnstarted (resultTermination settled) `shouldBe` 1
      logged fixture >>= (`shouldBe` ["gated reached", "gated released", "shutdown stopped"])
      -- Nothing of its demand is left: later ticks complete and run nothing for it.
      grantEach control owner [1, 1, 1]
      logged fixture >>= (`shouldBe` ["gated reached", "gated released", "shutdown stopped"])

-- Settlement ------------------------------------------------------------------------

settlementSpec ∷ Spec
settlementSpec = describe "a tick" $ do
  it "completes without a due update that cannot start, and an unaffected pause or stop settlement is the instance layer's, as before" $ bounded $
    withGatedOwner [slowTicker, holder] (testConfig instanceBounds') $ \fixture control owner → do
      _ ← periodic fixture owner "slowticker" (LogicalTicks 1)
      awaitPhase fixture owner "slowticker" Active
      expectDelivered fixture owner "slowticker" 1
      awaitWaits owner 1
      -- Every tick makes an update due behind a callback that has begun and waits; none can start, and none holds its tick.
      -- The callback's wait is for one tick.
      grantEach control owner [1]
      logged fixture >>= (`shouldBe` ["callback 1 begin", "callback 1 end"])

-- Arithmetic ------------------------------------------------------------------------

arithmeticSpec ∷ Spec
arithmeticSpec = describe "the cadence's arithmetic" $ do
  it "fails the instance, attributably, when the duration accrued toward an update cannot be represented, and leaves no tick held" $ bounded $
    withOwner [ticker] (testConfig instanceBounds') $ \fixture control owner → do
      _ ← periodic fixture owner "ticker" (LogicalTicks 100)
      awaitPhase fixture owner "ticker" Active
      -- The most a duration can be, twice: the second cannot be added to what was accrued.
      _ ← grantScheduledStep (scheduledEndpoint owner) maximumDuration
      void (awaitTicksComplete control owner)
      _ ← grantScheduledStep (scheduledEndpoint owner) maximumDuration
      void (awaitTicksComplete control owner)
      settled ← awaitSettled fixture "ticker"
      resultPhase settled `shouldBe` Failed
      fmap (\failure → (failureStage failure, failureMessage failure)) (failureOf' settled)
        `shouldSatisfy` maybe False (\(stage, message) → stage == StageUpdate && "cadence" `Text.isInfixOf` message)
      -- Ticks go on completing.
      grantEach control owner [1, 1]
  it "fails the instance when the duration an update would be handed is more nanoseconds than an integer holds, and the tick does not wait on it" $ bounded $
    withOwner [ticker] (testConfig instanceBounds') $ \fixture control owner → do
      _ ← periodic fixture owner "ticker" (LogicalTicks 3)
      awaitPhase fixture owner "ticker" Active
      grantEach control owner [9223372036854775808, 1, 1]
      settled ← awaitSettled fixture "ticker"
      resultPhase settled `shouldBe` Failed
      fmap failureStage (failureOf' settled) `shouldBe` Just StageUpdate
      -- Its update never ran; only its shutdown did, told why.
      logged fixture >>= (`shouldBe` ["shutdown failed"])
      grantEach control owner [1]

-- Determinism -----------------------------------------------------------------------

-- | Two periodic instances and events for one, fed while the owner is held and then
-- let go, and what was recorded. Each segment costs this much on the injected clock, and
-- a turn is cut by this service budget.
workload ∷ Word → Maybe Word → IO [Text]
workload cost budget = do
  fixture ← newIFixture
  writeIORef (sfDelay (sf fixture)) (fromIntegral cost)
  withBoundary $ \control runtime → do
    let bounds = defaultSchedulerBounds {boundServiceBudget = nanoseconds . fromIntegral <$> budget}
    owner ← startWith fixture runtime (instanceSpec fixture "deterministic" [pacedUpdate, ticker, holder] (testConfig instanceBounds') requiredPolicy bounds)
    flip finally (releaseGate (sf fixture) "hold") $ do
      _ ← admitWith fixture owner "pacedupdate" (InstanceRequest (moduleNamed "pacedupdate") (Periodic (LogicalTicks 3)) (Just "pacedupdate") OrdinaryClass [])
      _ ← periodic fixture owner "ticker" (LogicalTicks 2)
      awaitPhase fixture owner "pacedupdate" Active
      awaitPhase fixture owner "ticker" Active
      holdOwner fixture owner
      forM_ [1, 2, 3] (expectDelivered fixture owner "ticker")
      replicateM_ 3 (grantNow owner 1)
      releaseOwner fixture
      void (awaitTicksComplete control owner)
      awaitIdle (sf fixture)
      -- A few more ticks, one at a time, the owner at rest between.
      forM_ [1 .. 9 ∷ Int] $ \_ → do
        grantEach control owner [1]
        awaitIdle (sf fixture)
      logged fixture

determinismSpec ∷ Spec
determinismSpec = describe "determinism" $ do
  it "orders logical updates among the instance's other invocations, and hands each its duration, by the logical inputs alone, whatever segments cost and wherever the budget cuts a turn" $ bounded $ do
    baseline ← workload 0 Nothing
    -- The updates ran, in an order only the scheduler decides and every run reproduces.
    length (filter (Text.isPrefixOf "update ") baseline) `shouldSatisfy` (>= 4)
    workload 5 (Just 1) >>= (`shouldBe` baseline)
    workload 3 (Just 5) >>= (`shouldBe` baseline)
    workload 1000 (Just 2500) >>= (`shouldBe` baseline)
    workload 7 Nothing >>= (`shouldBe` baseline)
