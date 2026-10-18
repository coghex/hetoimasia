-- | Periodic updates on an elapsed cadence (LUA-24): the UI's interval on the owner's
-- monotonic source, tested against the injected clock and the fake timer, never a
-- sleep. Coalescing, lateness without a burst, @dt@ measured between starts and
-- rebased at a resume, and the owner's one timer shared between instances and an
-- ordinary elapsed waiter.
module Test.LuaRuntime.Instance.Elapsed (spec) where

import Control.Concurrent (yield)
import Control.Monad (forM_, join, void)
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Word (Word64)
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Hetoimasia.Foundation.Time (readInstant, scriptedSource)
import Hetoimasia.Runtime.Supervision (RuntimeControl)
import Hetoimasia.Scripting.Lua.Instance
import Hetoimasia.Scripting.Lua.Owner
import Hetoimasia.Scripting.Lua.Scheduled
import Test.Hspec (Spec, describe, it, shouldBe, shouldSatisfy)
import Test.LuaRuntime.Instance.Support
import Test.LuaRuntime.Scheduled.Support (SFixture (sfTimer), awaitDiagnostics, awaitEffect, awaitRegistrations, defaultSchedulerBounds, setClock)
import Test.LuaRuntime.Scheduler.Support (Reg (regMicroseconds), fireReg, liveRegs, nanoseconds)
import Test.LuaRuntime.Support (bounded, requiredPolicy, withBoundary)

-- The modules -------------------------------------------------------------------

-- | A periodic instance: each update records the @dt@ it was handed.
uiTicker ∷ ModuleSource
uiTicker =
  hooksModule
    "uiticker"
    [ "local function ns(x) return math.floor(x * 1e9 + 0.5) end"
    , "function init(self, api)"
    , "  api.connect('tick', function(self, event) " <> record <> "('event ' .. event.payload.n) end)"
    , "end"
    , "function update(self, dt) " <> record <> "('update ' .. ns(dt)) end"
    , "function shutdown(self, reason) " <> record <> "('shutdown ' .. reason) end"
    ]

-- | The same, whose event callback waits one logical tick.
uiWaiter ∷ ModuleSource
uiWaiter =
  hooksModule
    "uiwaiter"
    [ "local function ns(x) return math.floor(x * 1e9 + 0.5) end"
    , "function init(self, api)"
    , "  api.connect('tick', function(self, event)"
    , "    " <> record <> "('callback ' .. event.payload.n .. ' begin')"
    , "    sched.wait_ticks(1)"
    , "    " <> record <> "('callback ' .. event.payload.n .. ' end')"
    , "  end)"
    , "end"
    , "function update(self, dt) " <> record <> "('update ' .. ns(dt)) end"
    ]

-- | An update that reports the type and the value of the @dt@ Lua is handed.
floatReporter ∷ ModuleSource
floatReporter =
  hooksModule
    "floatreporter"
    [ "function update(self, dt) " <> record <> "(math.type(dt) .. ' ' .. dt) end"
    ]

-- | An ordinary elapsed waiter: a one-shot whose @run@ waits nine milliseconds.
sleeper ∷ ModuleSource
sleeper =
  hooksModule
    "sleeper"
    [ "function run(self, api)"
    , "  sched.wait_ns(9000000)"
    , "  " <> record <> "('slept')"
    , "end"
    ]

-- Driving -------------------------------------------------------------------------

-- | Admit an instance of the module of this name on an elapsed interval.
elapsed ∷ IFixture → ScheduledOwner → Text → Word64 → IO InstanceTicket
elapsed fixture owner name interval =
  admitWith fixture owner name (InstanceRequest (moduleNamed name) (Periodic (ElapsedEvery (nanoseconds interval))) (Just name) OrdinaryClass ["tick"])

withOwner ∷ [ModuleSource] → (IFixture → RuntimeControl → ScheduledOwner → IO a) → IO a
withOwner modules body = do
  fixture ← newIFixture
  withBoundary $ \control runtime → do
    owner ← startInstances fixture runtime "elapsed" modules (testConfig instanceBounds') requiredPolicy
    body fixture control owner

-- | Fire every registration the timer holds live, as its backend would on expiry.
fireLive ∷ IFixture → IO ()
fireLive fixture = liveRegs (sfTimer (sf fixture)) >>= mapM_ fireReg

-- | The microseconds each live registration was armed for.
liveMicroseconds ∷ IFixture → IO [Int]
liveMicroseconds fixture = map regMicroseconds <$> liveRegs (sfTimer (sf fixture))

-- | Wait until the live registrations are armed for exactly these microseconds: the
-- owner has looked, and brought its timer in line with what it now holds.
awaitLive ∷ IFixture → [Int] → IO ()
awaitLive fixture wanted = do
  held ← liveMicroseconds fixture
  if held == wanted then pure () else yield >> awaitLive fixture wanted

-- | Wait until the requests an example made from inside the owner's turn are in hand.
awaitHeld ∷ IORef [a] → IO ()
awaitHeld ref = do
  held ← readIORef ref
  if null held then yield >> awaitHeld ref else pure ()

-- | Block until the instance of this name has a due update, or none.
awaitOwed ∷ IFixture → ScheduledOwner → Text → Bool → IO ()
awaitOwed fixture owner name wanted = do
  owed ← maybe False snapshotUpdateOwed <$> snapshotOf fixture owner name
  if owed == wanted then pure () else yield >> awaitOwed fixture owner name wanted

awaitWaits ∷ ScheduledOwner → Int → IO ()
awaitWaits owner n = awaitDiagnostics owner (\counts → diagWaiting counts >= n)

spec ∷ Spec
spec = describe "elapsed cadence" $ do
  describe "an elapsed update" $ do
    it "is coalesced after a stall into one refresh, handed the time between update starts, and moves its deadline to the next point strictly in the future, with no catch-up burst" $ bounded $
      withOwner [uiTicker] $ \fixture _ owner → do
        setClock (sf fixture) 1000
        _ ← elapsed fixture owner "uiticker" 100
        awaitPhase fixture owner "uiticker" Active
        -- The first deadline is 1100, one interval after init.
        awaitRegistrations (sf fixture) 1
        awaitLive fixture [1]
        -- A stall of almost a second: nine points have passed, and one update is due.
        setClock (sf fixture) 1950
        fireLive fixture
        awaitEffect (sf fixture) "update 950"
        awaitRegistrations (sf fixture) 2
        logged fixture >>= (`shouldBe` ["update 950"])
        -- The next point strictly in the future is 2000: nothing is due before it.
        setClock (sf fixture) 1999
        fireLive fixture
        awaitRegistrations (sf fixture) 3
        logged fixture >>= (`shouldBe` ["update 950"])
        setClock (sf fixture) 2000
        fireLive fixture
        awaitEffect (sf fixture) "update 50"
        logged fixture >>= (`shouldBe` ["update 950", "update 50"])
    it "excludes an intentional pause from its dt: the baseline is rebased at the resume, and the first update newly due is one full interval after it" $ bounded $
      withOwner [uiTicker] $ \fixture _ owner → do
        setClock (sf fixture) 1000
        _ ← elapsed fixture owner "uiticker" 100
        awaitPhase fixture owner "uiticker" Active
        awaitRegistrations (sf fixture) 1
        setClock (sf fixture) 1050
        settleControl fixture owner "uiticker" InstancePause >>= (`shouldBe` ControlApplied)
        -- A paused instance holds no timer demand.
        awaitLive fixture []
        -- However long the pause, nothing is due, and nothing is due for it afterwards but a full interval on.
        setClock (sf fixture) 9000
        settleControl fixture owner "uiticker" InstanceResume >>= (`shouldBe` ControlApplied)
        awaitLive fixture [1]
        setClock (sf fixture) 9099
        fireLive fixture
        awaitRegistrations (sf fixture) 3
        logged fixture >>= (`shouldBe` [])
        setClock (sf fixture) 9100
        fireLive fixture
        awaitEffect (sf fixture) "update 100"
        logged fixture >>= (`shouldBe` ["update 100"])
    it "keeps one refresh unstarted behind an invocation that waits, coalescing the demand that follows, and drops no queued event" $ bounded $
      withOwner [uiWaiter] $ \fixture control owner → do
        setClock (sf fixture) 1000
        _ ← elapsed fixture owner "uiwaiter" 100
        awaitPhase fixture owner "uiwaiter" Active
        awaitRegistrations (sf fixture) 1
        expectDelivered fixture owner "uiwaiter" 1
        awaitWaits owner 1
        -- A point passes while the callback waits: unlike a logical point, it queues a refresh.
        setClock (sf fixture) 1950
        fireLive fixture
        awaitOwed fixture owner "uiwaiter" True
        awaitRegistrations (sf fixture) 2
        -- And another: it is coalesced into the one, which stays where it is.
        setClock (sf fixture) 2950
        fireLive fixture
        awaitRegistrations (sf fixture) 3
        awaitOwed fixture owner "uiwaiter" True
        -- An event accepted after the refresh fell due runs after it.
        expectDelivered fixture owner "uiwaiter" 2
        _ ← grantScheduledStep (scheduledEndpoint owner) (nanoseconds 1)
        void (awaitTicksComplete control owner)
        awaitEffect (sf fixture) "callback 2 begin"
        logged fixture >>= (`shouldBe` ["callback 1 begin", "callback 1 end", "update 1950", "callback 2 begin"])
  describe "a point reached and not yet served" $ do
    it "is dropped by a pause, so a pause and a resume processed between the sampling of the deadline and the serving of the point leave the next update a full interval after the resume" $ bounded $ do
      fixture ← newIFixture
      hook ← newIORef (pure ())
      withBoundary $ \_ runtime → do
        let base = instanceSpec fixture "stale" [uiTicker] (testConfig instanceBounds') requiredPolicy defaultSchedulerBounds
            -- A barrier at the clock's read: the turn's first, which samples the deadline.
            spec' = base {scheduledClock = scriptedSource (join (readIORef hook) >> readInstant (scheduledClock base))}
        owner ← startWith fixture runtime spec'
        setClock (sf fixture) 1000
        _ ← elapsed fixture owner "uiticker" 100
        awaitPhase fixture owner "uiticker" Active
        awaitRegistrations (sf fixture) 1
        identity ← idOf fixture "uiticker"
        receipts ← newIORef []
        -- Once, as the next turn reads the clock: the pause and the resume are accepted after
        -- the owner has drained what it was asked and before the boundary that serves the point.
        writeIORef hook $ do
          writeIORef hook (pure ())
          setClock (sf fixture) 1150
          pause ← requestInstanceControl (scheduledEndpoint owner) identity InstancePause
          resume ← requestInstanceControl (scheduledEndpoint owner) identity InstanceResume
          writeIORef receipts [pause, resume]
        setClock (sf fixture) 1150
        fireLive fixture
        awaitHeld receipts
        answers ← readIORef receipts
        forM_ answers $ \case
          InstanceControlAccepted receipt → waitInstanceControl receipt >>= (`shouldBe` ControlApplied)
          other → fail ("expected the request accepted, found " <> show other)
        -- The cadence is one full interval from the resume at 1150: 1250, and nothing is due at 1200.
        setClock (sf fixture) 1200
        fireLive fixture
        awaitRegistrations (sf fixture) 3
        logged fixture >>= (`shouldBe` [])
        setClock (sf fixture) 1250
        fireLive fixture
        awaitEffect (sf fixture) "update 100"
        logged fixture >>= (`shouldBe` ["update 100"])
  describe "its dt for Lua" $ do
    it "is a float number of seconds, the exact elapsed duration converted once" $ bounded $
      withOwner [floatReporter] $ \fixture _ owner → do
        setClock (sf fixture) 1000
        _ ← elapsed fixture owner "floatreporter" 100
        awaitPhase fixture owner "floatreporter" Active
        awaitRegistrations (sf fixture) 1
        -- A second and a half after init, on a cadence of a hundred nanoseconds.
        setClock (sf fixture) 1500001000
        fireLive fixture
        awaitEffect (sf fixture) "float 1.5"
        logged fixture >>= (`shouldBe` ["float 1.5"])
    it "is a float for a whole number of seconds too" $ bounded $
      withOwner [floatReporter] $ \fixture _ owner → do
        setClock (sf fixture) 1000
        _ ← elapsed fixture owner "floatreporter" 100
        awaitPhase fixture owner "floatreporter" Active
        awaitRegistrations (sf fixture) 1
        setClock (sf fixture) 1000001000
        fireLive fixture
        awaitEffect (sf fixture) "float 1.0"
        logged fixture >>= (`shouldBe` ["float 1.0"])
  describe "the owner's one timer" $ do
    it "is shared by instances and an ordinary waiter: pausing or stopping the earliest preserves the rest and recomputes the earliest deadline, and a stale wake revives nothing" $ bounded $
      withOwner [uiTicker, sleeper] $ \fixture _ owner → do
        setClock (sf fixture) 0
        _ ← elapsed fixture owner "uiticker" 1000000
        _ ← admitWith fixture owner "uiticker2" (InstanceRequest (ModuleRef "uiticker" "1") (Periodic (ElapsedEvery (nanoseconds 5000000))) (Just "uiticker2") OrdinaryClass ["tick"])
        _ ← admitWith fixture owner "sleeper" (InstanceRequest (moduleNamed "sleeper") RunOnce (Just "sleeper") OrdinaryClass [])
        awaitPhase fixture owner "uiticker" Active
        awaitPhase fixture owner "uiticker2" Active
        awaitPhase fixture owner "sleeper" Active
        awaitWaits owner 1
        -- One timer, armed for the earliest of the three: a millisecond.
        awaitLive fixture [1000]
        stale ← liveRegs (sfTimer (sf fixture))
        -- Pausing the earliest leaves the other cadence and the waiter: five milliseconds.
        settleControl fixture owner "uiticker" InstancePause >>= (`shouldBe` ControlApplied)
        awaitLive fixture [5000]
        -- Stopping that one leaves the waiter alone: nine.
        settleControl fixture owner "uiticker2" InstanceStop >>= (`shouldBe` ControlApplied)
        awaitLive fixture [9000]
        -- A wake of the registration the owner no longer holds, after the paused cadence's
        -- deadline, counts for nothing: it is not the live one.
        setClock (sf fixture) 2000000
        mapM_ fireReg stale
        awaitLive fixture [9000]
        -- The live wake finds the clock past that deadline and the cadence paused: nothing is
        -- due, and the owner arms for what remains of the waiter's.
        fireLive fixture
        awaitLive fixture [7000]
        logged fixture >>= (`shouldBe` ["shutdown stopped"])
        -- Resumed, it is one interval on from the resume, and nothing before.
        settleControl fixture owner "uiticker" InstanceResume >>= (`shouldBe` ControlApplied)
        awaitLive fixture [1000]
        setClock (sf fixture) 3000000
        fireLive fixture
        awaitEffect (sf fixture) "update 1000000"
    it "cancels the demand of an instance that stops, discards its unstarted refresh and counts it" $ bounded $
      withOwner [uiWaiter] $ \fixture _ owner → do
        setClock (sf fixture) 1000
        _ ← elapsed fixture owner "uiwaiter" 100
        awaitPhase fixture owner "uiwaiter" Active
        awaitRegistrations (sf fixture) 1
        expectDelivered fixture owner "uiwaiter" 1
        awaitWaits owner 1
        setClock (sf fixture) 1500
        fireLive fixture
        awaitOwed fixture owner "uiwaiter" True
        settleControl fixture owner "uiwaiter" InstanceStop >>= (`shouldBe` ControlApplied)
        settled ← awaitSettled fixture "uiwaiter"
        resultPhase settled `shouldBe` Stopped
        -- The refresh, and the callback that had begun and was closed.
        (terminationUnstarted (resultTermination settled), terminationClosed (resultTermination settled)) `shouldBe` (1, 1)
        awaitLive fixture []
  describe "its arithmetic" $ do
    it "fails the instance, attributably, when the first deadline cannot be represented, leaving no timer demand" $ bounded $
      withOwner [uiTicker] $ \fixture _ owner → do
        setClock (sf fixture) (maxBound - 10)
        _ ← elapsed fixture owner "uiticker" 100
        settled ← awaitSettled fixture "uiticker"
        resultPhase settled `shouldBe` Failed
        fmap failureMessage (failureOf' settled) `shouldSatisfy` maybe False (Text.isInfixOf "cadence")
        awaitLive fixture []
    it "fails the instance when the deadline after a reached one cannot be represented, leaving no timer demand" $ bounded $
      withOwner [uiTicker] $ \fixture _ owner → do
        setClock (sf fixture) (maxBound - 1000)
        _ ← elapsed fixture owner "uiticker" 600
        awaitPhase fixture owner "uiticker" Active
        awaitRegistrations (sf fixture) 1
        setClock (sf fixture) (maxBound - 300)
        fireLive fixture
        settled ← awaitSettled fixture "uiticker"
        resultPhase settled `shouldBe` Failed
        fmap failureMessage (failureOf' settled) `shouldSatisfy` maybe False (Text.isInfixOf "cadence")
        awaitLive fixture []
