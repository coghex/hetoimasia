-- | The scheduling behavior of requirements 4 to 10, end to end: real Lua tasks
-- run as coroutines on supervised scheduled owners, under the scheduler's policy,
-- classes, quanta, logical and elapsed time, budgets and control.
--
-- Where an example needs tasks admitted before the owner serves any, it admits them
-- while the owner is held inside a segment ('holding'), so that what it observes is
-- the scheduler's order and not the timing of the admitting threads.
module Test.LuaRuntime.Scheduled.Execution (spec) where

import Control.Concurrent.STM (atomically)
import Control.Concurrent (forkIO, killThread, yield)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar, tryReadMVar)
import Control.Exception (ExceptionWithContext (ExceptionWithContext), finally, throwIO)
import Control.Monad (forM_, replicateM_, void, when)
import Data.IORef (modifyIORef', newIORef, readIORef, writeIORef)
import qualified Data.List.NonEmpty as NonEmpty
import Data.Text (Text)
import Hetoimasia.Scripting.Lua.Scheduled
import GHC.Conc (BlockReason (BlockedOnSTM), ThreadStatus (ThreadBlocked, ThreadDied, ThreadFinished), threadStatus)
import Hetoimasia.Scripting.Lua.Scheduler (Candidate (..), PolicyView (..), servable)
import Hetoimasia.Scripting.Lua.Value (Value (VInteger, VText))
import Test.Hspec (Spec, describe, it, shouldBe, shouldSatisfy)
import Test.LuaRuntime.Scheduled.Support
import Test.LuaRuntime.Scheduler.Support (fireReg, liveRegs, nanoseconds)
import Test.LuaRuntime.Support (bounded, Broken (Broken), brokenIs, expectFatal, failExample, Gated (..), requiredPolicy, withBoundary, withBoundaryOpening)

-- | A task of the module's @spin@ entry, which records a label and a number and
-- yields, this many times.
spinning ∷ ServiceClass → TaskKind → Text → Int → TaskRequest
spinning serviceClass kind label n =
  request "spin" [VText label, VInteger (fromIntegral n)] serviceClass kind (Just label)

ordinary ∷ Text → Int → TaskRequest
ordinary = spinning OrdinaryClass OneShot

-- | Newest first among the servable, which is the opposite of the default.
newestFirst ∷ Policy
newestFirst = Policy "newest" $ \view → case reverse (servable view) of
  candidate : _ → candidateTask candidate
  [] → candidateTask (NonEmpty.head (viewReady view))

-- | One-shots before looped work.
oneShotsFirst ∷ Policy
oneShotsFirst = Policy "one-shots first" $ \view →
  case [candidate | candidate ← servable view, candidateKind candidate == OneShot] <> servable view of
    candidate : _ → candidateTask candidate
    [] → candidateTask (NonEmpty.head (viewReady view))

spec ∷ Spec
spec = describe "tasks run as coroutines on a scheduled owner" $ do
  it "runs a Lua task to completion and returns what its entry point returned" $ bounded $ do
    fixture ← newSFixture
    withBoundary $ \_ runtime → do
      owner ← startScheduled fixture runtime (scheduled fixture "echo" requiredPolicy defaultSchedulerBounds)
      ticket ← admitTask' fixture owner "echo" (request "echo" [VInteger 7] OrdinaryClass OneShot Nothing)
      outcomeOf ticket >>= (`shouldBe` Just [VInteger 7]) . taskReturned
      retireScheduled owner

  describe "the FIFO default and a test policy" $ do
    it "serves ready peers in the order they were admitted, and a yielded task goes behind them" $ bounded $ do
      fixture ← newSFixture
      withBoundaryOpening [openAllGates fixture] $ \_ runtime → do
        owner ← startScheduled fixture runtime (scheduled fixture "fifo" requiredPolicy defaultSchedulerBounds)
        tickets ← holding fixture owner (mapM (\label → admitTask' fixture owner label (ordinary label 2)) ["a", "b", "c"])
        mapM_ outcomeOf tickets
        taskEffects fixture >>= (`shouldBe` ["a1", "b1", "c1", "a2", "b2", "c2"])
        retireScheduled owner

    it "changes only the next choice under a policy chosen at creation" $ bounded $ do
      fixture ← newSFixture
      withBoundaryOpening [openAllGates fixture] $ \_ runtime → do
        owner ← startScheduled fixture runtime ((scheduled fixture "newest" requiredPolicy defaultSchedulerBounds) {scheduledPolicy = newestFirst})
        tickets ← holding fixture owner (mapM (\label → admitTask' fixture owner label (ordinary label 2)) ["a", "b", "c"])
        mapM_ outcomeOf tickets
        taskEffects fixture >>= (`shouldBe` ["c1", "c2", "b1", "b2", "a1", "a2"])
        retireScheduled owner

  describe "classes, quanta and one-shot placement" $ do
    it "runs each class at most its quantum per turn, and a yielded task behind its ready peers" $ bounded $ do
      fixture ← newSFixture
      withBoundaryOpening [openAllGates fixture] $ \_ runtime → do
        let bounds = defaultSchedulerBounds {boundQuanta = Quanta (Quantum 1) (Quantum 2) (Quantum 3)}
        owner ← startScheduled fixture runtime (scheduled fixture "quanta" requiredPolicy bounds)
        tickets ←
          holding fixture owner $
            mapM
              (\(label, serviceClass, n) → admitTask' fixture owner label (spinning serviceClass OneShot label n))
              [("b", BackgroundClass, 5), ("o1", OrdinaryClass, 3), ("c", ControlClass, 3), ("o2", OrdinaryClass, 3)]
        mapM_ outcomeOf tickets
        -- The task that held the owner used the control class's one segment of the
        -- first pass.
        taskEffects fixture
          >>= (`shouldBe` ["o11", "o21", "b1", "b2", "b3", "c1", "o12", "o22", "b4", "b5", "c2", "o13", "o23", "c3"])
        retireScheduled owner

    it "places a one-shot where the selected policy says" $ bounded $ do
      fixture ← newSFixture
      withBoundaryOpening [openAllGates fixture] $ \_ runtime → do
        owner ← startScheduled fixture runtime ((scheduled fixture "kinds" requiredPolicy defaultSchedulerBounds) {scheduledPolicy = oneShotsFirst})
        tickets ←
          holding fixture owner $ do
            looped ← admitTask' fixture owner "looped" (spinning OrdinaryClass Looped "l" 2)
            once ← admitTask' fixture owner "once" (spinning OrdinaryClass OneShot "s" 2)
            pure [looped, once]
        mapM_ outcomeOf tickets
        taskEffects fixture >>= (`shouldBe` ["s1", "s2", "l1", "l2"])
        retireScheduled owner

  describe "logical time" $ do
    it "hands a waiting task the tick it reached and the duration granted, and completion is observed through a supervised wait" $ bounded $ do
      fixture ← newSFixture
      withBoundary $ \control runtime → do
        owner ← startScheduled fixture runtime (scheduled fixture "ticks" requiredPolicy defaultSchedulerBounds)
        ticket ← admitTask' fixture owner "w" (request "wait_ticks" [VText "w", VInteger 3] OrdinaryClass OneShot (Just "w"))
        -- Grants are applied as the owner reaches a boundary, so the task must have
        -- begun to wait before they are made.
        awaitDiagnostics owner (\counts → diagWaiting counts >= 1)
        forM_ [5, 7, 11] $ \duration → grantScheduledStep (scheduledEndpoint owner) (nanoseconds duration)
        awaitTicksComplete control owner >>= (`shouldBe` TicksCompleted)
        _ ← outcomeOf ticket
        effects fixture >>= (`shouldBe` ["w before", "w after 1:3:23"])
        atomically (scheduledTick (scheduledEndpoint owner)) >>= (`shouldBe` 3)
        retireScheduled owner

  describe "elapsed time" $ do
    it "wakes a task exactly at its injected deadline and not before" $ bounded $ do
      fixture ← newSFixture
      withBoundary $ \_ runtime → do
        setClock fixture 1000
        owner ← startScheduled fixture runtime (scheduled fixture "sleep" requiredPolicy defaultSchedulerBounds)
        ticket ← admitTask' fixture owner "s" (request "sleep" [VText "s", VInteger 500] OrdinaryClass OneShot (Just "s"))
        -- The wait began at 1000, so the deadline is 1500, and the owner arms for it.
        awaitRegistrations fixture 1
        setClock fixture 1499
        liveRegs (sfTimer fixture) >>= mapM_ fireReg
        -- The wake found nothing due and the owner armed again: it has looked.
        awaitRegistrations fixture 2
        effects fixture >>= (`shouldBe` ["s before"])
        setClock fixture 1500
        liveRegs (sfTimer fixture) >>= mapM_ fireReg
        outcomeOf ticket >>= (`shouldBe` Just [VInteger 500]) . taskReturned
        effects fixture >>= (`shouldBe` ["s before", "s after 2:500:0"])
        retireScheduled owner

  describe "elapsed time past a Lua integer" $ do
    it "waits for a count of nanoseconds given as its two 32-bit halves, through the whole Word64 range, exactly" $ bounded $ do
      fixture ← newSFixture
      withBoundary $ \_ runtime → do
        setClock fixture 1000
        owner ← startScheduled fixture runtime (scheduled fixture "wide" requiredPolicy defaultSchedulerBounds)
        -- 2^63 + 5 nanoseconds: more than a Lua integer holds, within the 2^64 - 1 a duration holds.
        ticket ← admitTask' fixture owner "w" (request "sleep_wide" [VText "w", VInteger 2147483648, VInteger 5] OrdinaryClass OneShot (Just "w"))
        awaitRegistrations fixture 1
        setClock fixture (1000 + 9223372036854775808 + 4)
        liveRegs (sfTimer fixture) >>= mapM_ fireReg
        awaitRegistrations fixture 2
        effects fixture >>= (`shouldBe` ["w before"])
        setClock fixture (1000 + 9223372036854775808 + 5)
        liveRegs (sfTimer fixture) >>= mapM_ fireReg
        _ ← outcomeOf ticket
        effects fixture >>= (`shouldBe` ["w before", "w after 2"])
        retireScheduled owner

    it "refuses a pair that is not two words as a wait for nothing, and a deadline past the clock's range as a refused wait, never as a wrapped one" $ bounded $ do
      fixture ← newSFixture
      withBoundary $ \_ runtime → do
        setClock fixture 18446744073709551615
        owner ← startScheduled fixture runtime (scheduled fixture "range" requiredPolicy defaultSchedulerBounds)
        past ← admitTask' fixture owner "p" (request "sleep_wide" [VText "p", VInteger 0, VInteger 1] OrdinaryClass OneShot (Just "p"))
        outcomeOf past >>= \settled → case settled of
          SettledRefused _ → pure ()
          other → failExample ("a wait past the clock's range must be refused, found " <> show other)
        zero ← admitTask' fixture owner "z" (request "sleep_wide" [VText "z", VInteger 0, VInteger 0] OrdinaryClass OneShot (Just "z"))
        outcomeOf zero >>= \settled → case settled of
          SettledRefused _ → pure ()
          other → failExample ("a wait for nothing must be refused, found " <> show other)
        retireScheduled owner

  describe "the application told of a refused wait" $ do
    it "is told of each wait the scheduler refused, in order; the task still fails as it did" $ bounded $ do
      fixture ← newSFixture
      told ← newIORef []
      withBoundary $ \_ runtime → do
        setClock fixture 18446744073709551615
        owner ← startScheduled fixture runtime ((scheduled fixture "told" requiredPolicy defaultSchedulerBounds) {scheduledRefusedWait = \why → modifyIORef' told (why :)})
        past ← admitTask' fixture owner "p" (request "sleep_wide" [VText "p", VInteger 0, VInteger 1] OrdinaryClass OneShot (Just "p"))
        outcomeOf past >>= \settled → case settled of
          SettledRefused _ → pure ()
          other → failExample ("a wait past the clock's range must still be refused, found " <> show other)
        zero ← admitTask' fixture owner "z" (request "sleep_wide" [VText "z", VInteger 0, VInteger 0] OrdinaryClass OneShot (Just "z"))
        outcomeOf zero >>= \settled → case settled of
          SettledRefused _ → pure ()
          other → failExample ("a wait for nothing must still be refused, found " <> show other)
        retireScheduled owner
      readIORef told >>= (`shouldBe` [WaitDurationNotPositive, WaitDeadlineOverflow])
    it "deals with a refused wait at the boundary of its own segment: the peer behind the refused task is not chosen until the application has been told" $ bounded $ do
      fixture ← newSFixture
      withBoundaryOpening [openAllGates fixture] $ \_ runtime → do
        setClock fixture 18446744073709551615
        owner ← startScheduled fixture runtime ((scheduled fixture "boundary" requiredPolicy defaultSchedulerBounds) {scheduledRefusedWait = \_ → blockOn fixture "refusal"})
        ( do
          _ ← holding fixture owner $ do
            refused ← admitTask' fixture owner "a" (request "sleep_wide" [VText "a", VInteger 0, VInteger 1] OrdinaryClass OneShot (Just "a"))
            peer ← admitTask' fixture owner "b" (request "once" [VText "b"] OrdinaryClass OneShot (Just "b"))
            pure (refused, peer)
          awaitEntered fixture "refusal"
          -- the owner is held in the application's answer, at the refused segment's boundary: the refused task has
          -- run its segment, and the peer that was ready behind it has not been chosen
          effects fixture >>= \ran → (elem "a before" ran, elem "b" ran) `shouldBe` (True, False)
          releaseGate fixture "refusal"
          awaitEffect fixture "b"
          )
          `finally` (openAllGates fixture >> retireScheduled owner)
    it "does not acknowledge the owner's accounting at the boundary of a refused wait until the application has been told" $ bounded $ do
      fixture ← newSFixture
      withBoundaryOpening [openAllGates fixture] $ \control runtime → do
        setClock fixture 18446744073709551615
        owner ← startScheduled fixture runtime ((scheduled fixture "acknowledges" requiredPolicy defaultSchedulerBounds) {scheduledRefusedWait = \_ → blockOn fixture "refusal"})
        -- the waiter is a thread of the example's own: it is killed however the example ends
        waiterRef ← newIORef Nothing
        ( do
          -- the owner is held at the start of the refused task's segment, after the boundary that came before it
          writeIORef (sfObserver fixture) $ \context → when (contextName context == Just "a") (blockOn fixture "segment")
          ticket ← admitTask' fixture owner "a" (request "sleep_wide" [VText "a", VInteger 0, VInteger 1] OrdinaryClass OneShot (Just "a"))
          awaitEntered fixture "segment"
          -- a wait that begins here needs an acknowledgement written after it began: the first is the one at the
          -- boundary that follows the refused segment
          accounted ← newEmptyMVar
          waiter ← forkIO (awaitScheduledAccounting control owner >>= putMVar accounted)
          writeIORef waiterRef (Just waiter)
          let parked = threadStatus waiter >>= \case
                ThreadBlocked BlockedOnSTM → pure True
                ThreadFinished → pure False
                ThreadDied → pure False
                _ → yield >> parked
          parked >>= (`shouldBe` True)
          releaseGate fixture "segment"
          awaitEntered fixture "refusal"
          -- the owner is in the application's answer at that boundary: it has written no acknowledgement yet
          replicateM_ 500 yield
          tryReadMVar accounted >>= (`shouldBe` Nothing)
          releaseGate fixture "refusal"
          takeMVar accounted >>= (`shouldBe` AccountingComplete)
          void (outcomeOf ticket)
          )
          `finally` (readIORef waiterRef >>= mapM_ killThread >> openAllGates fixture >> retireScheduled owner)
    it "tells the application before the refused task's own close handlers run: a handler cannot keep the refusal from being reported" $ bounded $ do
      fixture ← newSFixture
      withBoundaryOpening [openAllGates fixture] $ \_ runtime → do
        setClock fixture 18446744073709551615
        owner ← startScheduled fixture runtime ((scheduled fixture "closing" requiredPolicy defaultSchedulerBounds) {scheduledRefusedWait = \_ → blockOn fixture "refusal"})
        ( do
          ticket ← admitTask' fixture owner "a" (request "refused_closing" [VText "a", VInteger 0, VInteger 1] OrdinaryClass OneShot (Just "a"))
          awaitEntered fixture "refusal"
          -- the task ran up to its refused wait and its continuation is suspended with a handler to run when it is
          -- closed: the application is being told, and the handler has not run
          effects fixture >>= \ran → (elem "a before" ran, elem "a closed" ran) `shouldBe` (True, False)
          releaseGate fixture "refusal"
          _ ← outcomeOf ticket
          -- once the application has answered, the close is made and the handler runs
          awaitEffect fixture "a closed"
          )
          `finally` (openAllGates fixture >> retireScheduled owner)
    it "leaves the turn when the application raises at that boundary: the peer behind the refused task never runs" $ bounded $ do
      fixture ← newSFixture
      ExceptionWithContext _ raised ← expectFatal $ \control runtime → do
        setClock fixture 18446744073709551615
        owner ← startScheduled fixture runtime ((scheduled fixture "leaves" requiredPolicy defaultSchedulerBounds) {scheduledRefusedWait = \_ → throwIO (Broken "refused wait")})
        ( do
            _ ← holding fixture owner $ do
              _ ← admitTask' fixture owner "a" (request "sleep_wide" [VText "a", VInteger 0, VInteger 1] OrdinaryClass OneShot (Just "a"))
              admitTask' fixture owner "b" (request "once" [VText "b"] OrdinaryClass OneShot (Just "b"))
            -- the refused task's own segment has run whatever the application does; the owner is then asked to retire,
            -- so that an application that does not raise ends the example at once instead of leaving it waiting for an
            -- owner that never fails
            awaitEffect fixture "a before"
            retireScheduled owner
            _ ← awaitScheduledTerminal control owner
            effects fixture >>= (`shouldSatisfy` notElem "b")
          )
          `finally` (openAllGates fixture >> retireScheduled owner)
      raised `shouldSatisfy` brokenIs "refused wait"

  describe "budgets" $ do
    it "ends a turn at an expired budget without preempting a segment or reordering tasks, and attributes the overruns" $ bounded $ do
      let workload bounds = do
            fixture ← newSFixture
            withBoundaryOpening [openAllGates fixture] $ \_ runtime → do
              owner ← startScheduled fixture runtime (scheduled fixture "budget" requiredPolicy bounds)
              tickets ←
                holding fixture owner $
                  mapM
                    (\label → admitTask' fixture owner label (request "costly" [VText label, VInteger 2, VInteger 60] OrdinaryClass OneShot (Just label)))
                    ["a", "b", "c"]
              mapM_ outcomeOf tickets
              order ← taskEffects fixture
              counts ← atomically (scheduledDiagnostics (scheduledEndpoint owner))
              retireScheduled owner
              pure (order, counts)
      (unbudgeted, plain) ← workload defaultSchedulerBounds
      (budgeted, counts) ← workload defaultSchedulerBounds {boundServiceBudget = Just (nanoseconds 100)}
      budgeted `shouldBe` unbudgeted
      budgeted `shouldBe` ["a1", "b1", "c1", "a2", "b2", "c2"]
      diagOverruns plain `shouldBe` 0
      diagOverruns counts `shouldSatisfy` (> 0)
      map overrunEntry (diagOverrunSites counts) `shouldBe` ["costly"]

  describe "pause, resume and stop at safe boundaries" $ do
    it "pauses a task from another task's request, and resumes it at the tail" $ bounded $ do
      fixture ← newSFixture
      withBoundaryOpening [openAllGates fixture] $ \_ runtime → do
        owner ← startScheduled fixture runtime (scheduled fixture "control" requiredPolicy defaultSchedulerBounds)
        (target, controller) ←
          holding fixture owner $
            (,)
              <$> admitTask' fixture owner "p" (ordinary "p" 4)
              <*> admitTask' fixture owner "c" (request "controls" [VText "c", VText "p", VText "pause"] OrdinaryClass OneShot (Just "c"))
        _ ← outcomeOf controller
        -- "p" ran once, "c" asked for it to be paused, and it did not run again.
        taskEffects fixture >>= (`shouldBe` ["p1", "c pause p -> 0", "c after"])
        let endpoint = scheduledEndpoint owner
        requestTaskControl endpoint (ticketTask target) RequestResume >>= \case
          TaskControlAccepted receipt → waitControl receipt >>= (`shouldSatisfy` \settled → settledResult settled == ControlApplied)
          other → failExample ("the resume was not accepted: " <> show other)
        _ ← outcomeOf target
        taskEffects fixture >>= (`shouldBe` ["p1", "c pause p -> 0", "c after", "p2", "p3", "p4"])
        retireScheduled owner

    it "applies a request about the running task when its segment returns" $ bounded $ do
      fixture ← newSFixture
      withBoundaryOpening [openAllGates fixture] $ \_ runtime → do
        owner ← startScheduled fixture runtime (scheduled fixture "self" requiredPolicy defaultSchedulerBounds)
        ticket ← holding fixture owner (admitTask' fixture owner "s" (request "controls" [VText "s", VText "s", VText "pause"] OrdinaryClass OneShot (Just "s")))
        -- It asked for its own pause inside its first segment and yielded; the pause
        -- applied at the boundary, so its second segment waits for a resume.
        awaitDiagnostics owner (\counts → diagYielded counts >= 1)
        awaitIdle fixture
        taskEffects fixture >>= (`shouldBe` ["s pause s -> 0"])
        requestTaskControl (scheduledEndpoint owner) (ticketTask ticket) RequestResume >>= \case
          TaskControlAccepted _ → pure ()
          other → failExample ("the resume was not accepted: " <> show other)
        _ ← outcomeOf ticket
        taskEffects fixture >>= (`shouldBe` ["s pause s -> 0", "s after"])
        retireScheduled owner

    it "applies a stop of the running task when its segment returns, closing its coroutine" $ bounded $ do
      fixture ← newSFixture
      withBoundaryOpening [openAllGates fixture] $ \_ runtime → do
        owner ← startScheduled fixture runtime (scheduled fixture "self stop" requiredPolicy defaultSchedulerBounds)
        ticket ← holding fixture owner (admitTask' fixture owner "k" (request "controls" [VText "k", VText "k", VText "stop"] OrdinaryClass OneShot (Just "k")))
        outcomeOf ticket >>= \case
          SettledCancelled → pure ()
          other → failExample ("expected the task to be cancelled, found " <> show other)
        -- It asked inside its first segment and was stopped as that returned, so it
        -- never ran the line after its yield.
        taskEffects fixture >>= (`shouldBe` ["k stop k -> 0"])
        retireScheduled owner

    it "stops a task, closing its coroutine, and settles it as cancelled" $ bounded $ do
      fixture ← newSFixture
      withBoundaryOpening [openAllGates fixture] $ \_ runtime → do
        owner ← startScheduled fixture runtime (scheduled fixture "stop" requiredPolicy defaultSchedulerBounds)
        (victim, killer) ←
          holding fixture owner $
            (,)
              <$> admitTask' fixture owner "v" (request "forever" [VText "v"] OrdinaryClass Looped (Just "v"))
              <*> admitTask' fixture owner "k" (request "controls" [VText "k", VText "v", VText "stop"] OrdinaryClass OneShot (Just "k"))
        _ ← outcomeOf killer
        outcomeOf victim >>= \case
          SettledCancelled → pure ()
          other → failExample ("expected the task to be cancelled, found " <> show other)
        retireScheduled owner
