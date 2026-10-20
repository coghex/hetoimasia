-- | Sweeps over the configurations in which the instance layer's two invariants
-- could fail, so that a case nobody thought of is a member of a set and not a
-- scenario of its own.
--
-- /Order./ An invocation the scheduler had no room for is tried again wherever room
-- appears, before another segment is chosen or a turn ends for budget, so the order
-- in which a workload's effects happen never depends on where the turns are cut.
-- Every bound that can refuse (the scheduler's result places, its admission queue
-- with its active slots) is exhausted, room is released by each site that releases
-- it, and the effects must come out identical however the service budget cuts the
-- turns.
--
-- /Counting./ A one-shot's @run@ is owed from the success of its @init@ until it
-- begins, whether the scheduler took it, queued it or refused it, whether a pause
-- took it back or holds it, and the ending, however it comes, discards it exactly
-- once, among the invocations that never began.
module Test.LuaRuntime.Instance.Sweep (spec) where

import Control.Concurrent (yield)
import Control.Concurrent.STM (atomically)
import Control.Monad (forM, forM_, unless, void, when)
import Data.IORef (writeIORef)
import qualified Data.Text as Text
import Data.Text (Text)
import Data.Word (Word64)
import System.Timeout (timeout)
import Hetoimasia.Runtime.Supervision (RuntimeControl)
import Hetoimasia.Scripting.Lua.Instance
import Hetoimasia.Scripting.Lua.Scheduled
import Hetoimasia.Scripting.Lua.Value (Value (VText))
import Test.Hspec (Spec, describe, it, shouldBe, shouldSatisfy)
import Test.LuaRuntime.Instance.Support
import Test.LuaRuntime.Scheduled.Support
  ( SFixture (sfDelay)
  , awaitDiagnostics
  , awaitEffect
  , awaitEntered
  , awaitScheduledTerminal
  , defaultSchedulerBounds
  , releaseGate
  , request
  )
import Test.LuaRuntime.Scheduler.Support (nanoseconds)
import Test.LuaRuntime.Support (Gated (..), bounded, requiredPolicy, withBoundary, withBoundaryOpening)

-- The order of effects ------------------------------------------------------------------

-- | The bound that is exhausted when the instances' invocations are first tried.
data Exhausted
  = -- | The scheduler's result places: two held by ordinary tasks nobody has read.
    ResultsFull
  | -- | The scheduler's admission queue, with its one active slot: a task keeps its slot
    -- until its result is read or forgotten.
    QueueFull
  | -- | Few active slots and a short admission queue, which the instances' callbacks, each
    -- admitting an ordinary task, and their next invocations compete for.
    Contended
  | -- | The same, with every result place but the last taken by ordinary tasks whose
    -- tickets were forgotten before they ran, so the places come back only as the owner
    -- gives back what finished tasks held.
    ContendedForgotten
  deriving (Eq, Show)

-- | How many events each of the two instances is delivered.
eventsPer ∷ Exhausted → Int
eventsPer = \case
  Contended → 4
  ContendedForgotten → 4
  _ → 2

-- | What frees the room that refused the invocations.
data Release
  = -- | Only the workload's own progress: an invocation's end, whose result place is
    -- given back at the boundary.
    Natural
  | -- | The application reads a finished ordinary task's result: the unread one, or the
    -- one that holds the only active slot.
    Observe
  | -- | The application forgets that ticket instead.
    Forget
  deriving (Eq, Show)

-- | What each callback costs on the injected clock, and the service budget: where
-- turns end follows from the pair.
data Cut = Cut !Word64 !(Maybe Word64)
  deriving (Show)

-- | Every cut: none, after every costly segment, after every second, after every third.
cuts ∷ [Cut]
cuts = [Cut 0 Nothing, Cut 5 (Just 1), Cut 1000 (Just 1500), Cut 1000 (Just 2500)]

-- | The configurations: each bound with the release sites that apply to it.
configurations ∷ [(Exhausted, Release)]
configurations =
  [ (ResultsFull, Natural)
  , (ResultsFull, Observe)
  , (ResultsFull, Forget)
  , (QueueFull, Observe)
  , (QueueFull, Forget)
  , (Contended, Natural)
  , (Contended, Observe)
  , (Contended, Forget)
  , (ContendedForgotten, Natural)
  ]

-- | Everything the workload recorded, in order. Two instances are each delivered two
-- events while the owner is held inside an ordinary task, the bound is exhausted, and
-- room is released as the configuration says before the owner goes on.
orderOf ∷ Exhausted → Release → Cut → IO [Text]
orderOf Contended release cut = contendedOrder (Shape 1 3 0) release cut
orderOf ContendedForgotten release cut = contendedOrder (Shape 3 6 2) release cut
orderOf exhausted release (Cut cost budget) = do
  fixture ← newIFixture
  writeIORef (sfDelay (sf fixture)) cost
  withBoundaryOpening [openAllGates fixture] $ \control runtime → do
    let bounds =
          defaultSchedulerBounds
            { boundServiceBudget = nanoseconds <$> budget
            , boundRetainedResults = if exhausted == ResultsFull then 4 else 32
            , boundActiveTasks = if exhausted == QueueFull then 1 else 16
            , boundQueuedAdmissions = if exhausted == QueueFull then 2 else 16
            }
    owner ←
      startWith fixture runtime $
        instanceSpec fixture "order sweep" [delayedEcho, plainModule] (testConfig (InstanceBounds 2 2 8 8)) requiredPolicy bounds
    _ ← admit fixture owner "a" (moduleNamed "delayedecho")
    _ ← admit fixture owner "b" (moduleNamed "delayedecho")
    awaitPhase fixture owner "a" Active
    awaitPhase fixture owner "b" Active
    -- A finished task whose result nobody has read holds a place, when places are the bound.
    unread ←
      if exhausted == ResultsFull
        then do
          ticket ← admitOrdinary owner "once" "unread"
          awaitEffect (sf fixture) "unread"
          pure [ticket]
        else pure []
    -- The owner is held inside a task, so that what follows is all accepted before any
    -- of it is served.
    occupant ← admitOrdinary owner "holds" "plain"
    awaitEntered (sf fixture) "plain"
    queued ←
      if exhausted == QueueFull
        then forM ["q1", "q2"] (admitOrdinary owner "once")
        else pure []
    forM_ [1, 2] $ \n → do
      expectDelivered fixture owner "a" n
      expectDelivered fixture owner "b" n
    -- What can be freed before the owner goes on.
    case (exhausted, release) of
      (ResultsFull, Observe) → forM_ unread (void . waitTask)
      (ResultsFull, Forget) → forM_ unread forgetTask
      _ → pure ()
    releaseGate (sf fixture) "plain"
    -- A task holds its active slot until its result is read or forgotten, so what the
    -- application reads or forgets, in the order the tasks were admitted, frees the slots
    -- that the queued work and the invocations wait for.
    when (exhausted == QueueFull) $
      forM_ (occupant : queued) $ \ticket → case release of
        Forget → forgetTask ticket
        _ → void (waitTask ticket)
    awaitTicks control fixture owner 4
    logged fixture
  where
    admitOrdinary owner entry label =
      admitScheduledTask (scheduledEndpoint owner) (request entry [VText label] OrdinaryClass OneShot Nothing) >>= \case
        TaskAccepted _ ticket → pure ticket
        other → fail ("expected the task accepted, found " <> show other)

-- | How a contended workload is set up: the finished tasks whose results nobody reads, the
-- active slots, and the tasks whose tickets are forgotten before they run.
data Shape = Shape !Int !Int !Int

-- | The same for instances that compete with their own tasks: each callback admits an
-- ordinary task, and forgets its ticket, and the scheduler has three active slots, one
-- of which can be held for good by a task whose result nobody reads, and an admission
-- queue of three. The first instance's first callback fills the queue, so its next
-- invocation is refused when that callback ends, and the room that a boundary then frees
-- is taken by that invocation, or by the other instance's, depending on when what was
-- refused is tried again.
contendedOrder ∷ Shape → Release → Cut → IO [Text]
contendedOrder (Shape unreadHeld active forgotten) release (Cut cost budget) = do
  fixture ← newIFixture
  writeIORef (sfDelay (sf fixture)) cost
  withBoundaryOpening [openAllGates fixture] $ \control runtime → do
    let bounds =
          defaultSchedulerBounds
            { boundServiceBudget = nanoseconds <$> budget
            , boundActiveTasks = active
            , boundRetainedResults = 6
            , boundQueuedAdmissions = 3
            }
    owner ←
      startWith fixture runtime $
        instanceSpec fixture "contended" [spawner, holder, plainModule] (testConfig (InstanceBounds 3 3 8 8)) requiredPolicy bounds
    _ ← admit fixture owner "a" (moduleNamed "spawner")
    _ ← admit fixture owner "b" (moduleNamed "spawner")
    awaitPhase fixture owner "a" Active
    awaitPhase fixture owner "b" Active
    -- Finished tasks whose results nobody reads each keep a place and a slot.
    unreadTickets ←
      forM [1 .. unreadHeld] $ \i → do
        ticket ←
          admitScheduledTask (scheduledEndpoint owner) (request "once" [VText (Text.pack ("unread" <> show i))] OrdinaryClass OneShot Nothing) >>= \case
            TaskAccepted _ held → pure held
            other → fail ("expected the task accepted, found " <> show other)
        awaitEffect (sf fixture) (Text.pack ("unread" <> show i))
        pure ticket
    holdOwner fixture owner
    -- Admitted while the owner is held, so none has run when its ticket is forgotten.
    forM_ [1 .. forgotten] $ \i →
      admitScheduledTask (scheduledEndpoint owner) (request "once" [VText (Text.pack ("forgotten " <> show i))] OrdinaryClass OneShot Nothing) >>= \case
        TaskAccepted _ ticket → forgetTask ticket
        other → fail ("expected the task accepted, found " <> show other)
    forM_ [1 .. eventsPer Contended] $ \n → do
      expectDelivered fixture owner "a" n
      expectDelivered fixture owner "b" n
    case release of
      Natural → pure ()
      Observe → forM_ (take 1 unreadTickets) (void . waitTask)
      Forget → forM_ (take 1 unreadTickets) forgetTask
    releaseOwner fixture
    awaitTicks control fixture owner (2 * eventsPer Contended)
    -- Every task that was admitted has finished: the spawned ones too.
    awaitDiagnostics owner (\d → diagAdmitted d == diagCompleted d + diagFailed d + diagCancelled d)
    logged fixture

-- | An instance's next invocation, admitted behind a slot that its last invocation still
-- holds, against an ordinary task that a grant makes ready at the same boundary: the
-- slot is given back by the owner at that boundary, and the invocation, admitted first,
-- must be activated and chosen before the task whose wake is newer, whether or not the
-- turn is cut there. Nothing else is waiting for the owner at that boundary: the events
-- were delivered while it was held, and their jobs are long served.
wakeOrder ∷ Cut → IO [Text]
wakeOrder (Cut cost budget) = do
  fixture ← newIFixture
  writeIORef (sfDelay (sf fixture)) cost
  withBoundaryOpening [openAllGates fixture] $ \_ runtime → do
    let bounds = defaultSchedulerBounds {boundServiceBudget = nanoseconds <$> budget, boundActiveTasks = 2}
    owner ←
      startWith fixture runtime $
        instanceSpec fixture "wake order" [midGate, holder, plainModule] (testConfig (InstanceBounds 2 3 4 4)) requiredPolicy bounds
    _ ← admit fixture owner "a" (moduleNamed "midgate")
    awaitPhase fixture owner "a" Active
    -- The task waits for a tick nobody has granted: it holds the second slot.
    _ ← admitScheduledTask (scheduledEndpoint owner) (request "wakes" [VText "woke"] OrdinaryClass OneShot Nothing)
    awaitDiagnosticsWaiting owner
    holdOwner fixture owner
    expectDelivered fixture owner "a" 1
    expectDelivered fixture owner "a" 2
    releaseOwner fixture
    awaitEntered (sf fixture) "mid"
    -- Accepted now, applied at the boundary the invocation's end makes.
    _ ← grantScheduledStep (scheduledEndpoint owner) (nanoseconds 1)
    releaseGate (sf fixture) "mid"
    awaitEffect (sf fixture) "woke"
    logged fixture

-- | Room that appears at a boundary where an instance is blocked and another's job is
-- waiting goes to the blocked instance, whose number is lower, and not to the job that
-- was accepted first: three result places are held for good, the fourth by the first
-- instance's invocation, whose next one is refused when it ends; the second instance's
-- delivery was accepted before that instance's second event, and its job is served at
-- the boundary where the place is given back.
jobOrder ∷ Cut → IO [Text]
jobOrder (Cut cost budget) = do
  fixture ← newIFixture
  writeIORef (sfDelay (sf fixture)) cost
  withBoundaryOpening [openAllGates fixture] $ \control runtime → do
    let bounds = defaultSchedulerBounds {boundServiceBudget = nanoseconds <$> budget, boundRetainedResults = 4}
    owner ←
      startWith fixture runtime $
        instanceSpec fixture "job order" [midGate, plainModule] (testConfig (InstanceBounds 2 2 4 4)) requiredPolicy bounds
    _ ← admit fixture owner "a" (moduleNamed "midgate")
    _ ← admit fixture owner "b" (moduleNamed "midgate")
    awaitPhase fixture owner "a" Active
    awaitPhase fixture owner "b" Active
    forM_ [1 .. 3 ∷ Int] $ \i → do
      let label = Text.pack ("unread" <> show i)
      _ ← admitScheduledTask (scheduledEndpoint owner) (request "once" [VText label] OrdinaryClass OneShot Nothing)
      awaitEffect (sf fixture) label
    expectDelivered fixture owner "a" 1
    awaitEntered (sf fixture) "mid"
    expectDelivered fixture owner "b" 1
    expectDelivered fixture owner "a" 2
    releaseGate (sf fixture) "mid"
    awaitTicks control fixture owner 3
    logged fixture

-- | Wait, without sleeping, until this many ticks were recorded; if they never are,
-- fail with what was.
awaitTicks ∷ RuntimeControl → IFixture → ScheduledOwner → Int → IO ()
awaitTicks control fixture owner wanted =
  timeout (10 * 1000 * 1000) wait >>= \case
    Just () → pure ()
    Nothing → do
      seen ← logged fixture
      counts ← atomically (scheduledDiagnostics (scheduledEndpoint owner))
      status ← timeout (2 * 1000 * 1000) (awaitScheduledTerminal control owner)
      fail ("expected " <> show wanted <> " ticks, found " <> show seen <> "; the scheduler: " <> show counts <> "; the owner: " <> show status)
  where
    wait = do
      seen ← length . filter ("tick" `Text.isPrefixOf`) <$> logged fixture
      unless (seen >= wanted) (yield >> wait)

-- The count of an owed run ----------------------------------------------------------------

-- | Where the run is when the instance ends.
data Base
  = -- | The scheduler took it and queued it behind work that holds the only active slot.
    RunQueued
  | -- | The scheduler refused it: its admission queue is full.
    RefusedQueue
  | -- | The scheduler refused it: its result places are all held.
    RefusedResults
  deriving (Eq, Show)

-- | What was done to the instance before it ended.
data Pausing
  = Untouched
  | -- | Paused, and left so.
    WasPaused
  | -- | Paused and resumed.
    WasResumed
  deriving (Eq, Show)

-- | How it ends.
data Ending
  = -- | The application stops it.
    ByStop
  | -- | Its owner retires.
    ByRetire
  | -- | Its owner is cancelled.
    ByCancel
  deriving (Eq, Show)

-- | How many unstarted invocations the instance settled as having discarded, when a
-- one-shot with this many events behind its @run@ ends this way.
unstartedAt ∷ Base → Pausing → Ending → Int → IO Int
unstartedAt base pausing ending events = do
  fixture ← newIFixture
  withBoundaryOpening [openAllGates fixture] $ \control runtime → do
    let bounds =
          defaultSchedulerBounds
            { boundActiveTasks = 1
            , boundQueuedAdmissions = if base == RefusedQueue then 1 else 16
            , boundRetainedResults = if base == RefusedResults then 2 else 32
            }
    owner ←
      startWith fixture runtime $
        instanceSpec fixture "owed run" [gateOneShot, plainModule] (testConfig (InstanceBounds 1 2 4 4)) requiredPolicy bounds
    -- The only active slot is held by a task that waits for ticks nobody grants.
    _ ← admitOrdinary owner "waits" "w"
    awaitDiagnosticsWaiting owner
    _ ← admitWith fixture owner "a" (InstanceRequest (moduleNamed "gateoneshot") RunOnce (Just "a") OrdinaryClass ["tick"])
    -- Its init is held at a gate, so what refuses its run is in place before the run is tried.
    awaitEntered (sf fixture) "init"
    when (base /= RunQueued) $ void (admitOrdinary owner "once" "filler")
    forM_ [1 .. events] (expectDelivered fixture owner "a")
    releaseGate (sf fixture) "init"
    awaitPhase fixture owner "a" Active
    -- The owner has tried to place its run, and it is queued or was refused: waited for as
    -- the scheduler counts it, not assumed.
    awaitDiagnostics owner $ \counts → if base == RunQueued then diagQueued counts >= 1 else diagRejected counts >= 1
    when (pausing /= Untouched) $ settleControl fixture owner "a" InstancePause >>= (`shouldBe` ControlApplied)
    -- A resume is applied, and the run looked for again, before its request settles.
    when (pausing == WasResumed) $ settleControl fixture owner "a" InstanceResume >>= (`shouldBe` ControlApplied)
    case ending of
      ByStop → settleControl fixture owner "a" InstanceStop >>= (`shouldBe` ControlApplied)
      ByRetire → retireScheduled owner >> void (awaitScheduledTerminal control owner)
      ByCancel → cancelScheduled owner >> void (awaitScheduledTerminal control owner)
    settled ← awaitSettled fixture "a"
    pure (terminationUnstarted (resultTermination settled))
  where
    admitOrdinary owner entry label =
      admitScheduledTask (scheduledEndpoint owner) (request entry [VText label] OrdinaryClass OneShot Nothing) >>= \case
        TaskAccepted _ ticket → pure ticket
        other → fail ("expected the task accepted, found " <> show other)

spec ∷ Spec
spec = describe "the invariants, swept over the configurations that could break them" $ do
  describe "the order of effects, however turns are cut" $
    forM_ configurations $ \(exhausted, release) →
      it ("is the same for every budget when " <> show exhausted <> " is exhausted and room is freed by " <> show release) $ bounded $ do
        runs ← forM cuts (orderOf exhausted release)
        case runs of
          [] → fail "no cuts"
          baseline : others → do
            forM_ others (`shouldBe` baseline)
            -- Every event of every instance was handled, and in the order the instances were
            -- admitted: the two advance together, each one's next invocation after the
            -- other's current one, however the room that refused them was freed.
            let ticks = filter ("tick" `Text.isPrefixOf`) baseline
                events = eventsPer exhausted
            ticks
              `shouldBe` [ Text.pack ("tick " <> show name <> " n=" <> show n)
                         | n ← [1 .. events]
                         , name ← [1, 2 ∷ Int]
                         ]
  describe "the room an owner gives back at a boundary" $ do
    it "goes to the invocation that was admitted first, before a task whose wake is newer, however turns are cut" $ bounded $ do
      runs ← forM cuts wakeOrder
      forM_ runs (`shouldBe` ["tick 1 n=1", "tick 1 n=2", "woke"])
    it "goes to the blocked instance of the lowest number, before the job of one accepted earlier, however turns are cut" $ bounded $ do
      runs ← forM cuts jobOrder
      forM_ runs (`shouldBe` ["unread1", "unread2", "unread3", "tick 1 n=1", "tick 1 n=2", "tick 2 n=1"])
  describe "a one-shot's owed run, counted once" $ do
    forM_ [RunQueued, RefusedQueue, RefusedResults] $ \base →
      forM_ [Untouched, WasPaused, WasResumed] $ \pausing →
        forM_ [ByStop, ByRetire, ByCancel] $ \ending →
          it ("is discarded exactly once, with the events behind it, when it is " <> show base <> ", " <> show pausing <> " and the instance ends " <> show ending) $ bounded $ do
            counts ← forM [0, 2] (unstartedAt base pausing ending)
            -- The run, and each event that had not begun.
            counts `shouldBe` [1, 3]
    it "is not owed before its init has succeeded: an instance whose init fails discards no run" $ bounded $ do
      fixture ← newIFixture
      withBoundary $ \_ runtime → do
        owner ←
          startWith fixture runtime $
            instanceSpec fixture "failed init" [failingOneShot] (testConfig (InstanceBounds 1 2 4 4)) requiredPolicy defaultSchedulerBounds
        _ ← admitWith fixture owner "a" (InstanceRequest (moduleNamed "failingoneshot") RunOnce (Just "a") OrdinaryClass ["tick"])
        settled ← awaitSettled fixture "a"
        resultOutcome settled `shouldSatisfy` \case InstanceFailed _ → True; _ → False
        terminationUnstarted (resultTermination settled) `shouldBe` 0
    it "is not counted once it has begun" $ bounded $ do
      fixture ← newIFixture
      withBoundaryOpening [openAllGates fixture] $ \_ runtime → do
        owner ←
          startWith fixture runtime $
            instanceSpec fixture "begun run" [gateOneShot] (testConfig (InstanceBounds 1 2 4 4)) requiredPolicy defaultSchedulerBounds
        _ ← admitWith fixture owner "a" (InstanceRequest (moduleNamed "gateoneshot") RunOnce (Just "a") OrdinaryClass ["tick"])
        awaitEntered (sf fixture) "init"
        forM_ [1, 2] (expectDelivered fixture owner "a")
        releaseGate (sf fixture) "init"
        settled ← awaitSettled fixture "a"
        -- The run ran and the instance completed; the two events never began.
        resultOutcome settled `shouldSatisfy` \case InstanceCompleted → True; _ → False
        terminationUnstarted (resultTermination settled) `shouldBe` 2
