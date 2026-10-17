-- | Budgets and overruns (requirement 9): an expired budget ends a turn without
-- preempting a segment and without reordering ready tasks, the unfinished pass
-- continues where it was cut, and overruns are counted and attributed.
module Test.LuaRuntime.Scheduler.Budget (spec) where

import Control.Concurrent.STM (atomically)
import Control.Exception (SomeException, try)
import Control.Monad (forM, forM_)
import Data.IORef (newIORef, readIORef, writeIORef)
import qualified Data.Text as Text
import Data.Word (Word64)
import Hetoimasia.Scripting.Lua.Scheduler
import Test.Hspec (Spec, describe, it, shouldBe, shouldSatisfy)
import Test.LuaRuntime.Scheduler.Support

budgeted ∷ Maybe Word64 → SchedulerBounds → SchedulerBounds
budgeted budget bounds = bounds {boundServiceBudget = nanoseconds <$> budget}

spec ∷ Spec
spec = describe "service budgets and overruns" $ do
  it "ends a turn at an expired budget without preempting a segment, and serves the same order a run without a budget does" $ do
    let work budget = do
          rig ← newRigWith defaultOptions {optBounds = budgeted budget defaultBounds}
          forM_ ["a", "b", "c"] $ \name → admit rig name OrdinaryClass Looped >> script rig name (repeat (cost rig 60 (yielded name)))
          pure rig
    plain ← work Nothing
    unbudgeted ← runSegments plain 6
    rig ← work (Just 100)
    first ← turn rig
    -- The first turn ran two segments: the second ended at 120, past the deadline
    -- of 100, which expired the budget and was counted as an overrun. Nothing
    -- interrupted it.
    (turnSegments first, turnEnd first) `shouldBe` (2, TurnBudgetExpired)
    ran rig >>= (`shouldBe` ["a", "b"])
    diagOverruns <$> diagnostics rig >>= (`shouldBe` 1)
    budgetedOrder ← runSegments rig 6
    budgetedOrder `shouldBe` unbudgeted
    budgetedOrder `shouldBe` ["a", "b", "c", "a", "b", "c"]

  it "expires when the clock reaches the deadline, not only after it" $ do
    rig ← newRigWith defaultOptions {optBounds = budgeted (Just 20) defaultBounds}
    forM_ ["a", "b", "c"] $ \name → admit rig name OrdinaryClass Looped >> script rig name (repeat (cost rig 10 (yielded name)))
    report ← turn rig
    (turnSegments report, turnEnd report) `shouldBe` (2, TurnBudgetExpired)
    -- Ending exactly at the deadline expires the budget, and is not an overrun.
    diagOverruns <$> diagnostics rig >>= (`shouldBe` 0)

  it "keeps a suspended continuation closable when the clock fails after its segment returned" $ do
    rig ← newRigWith defaultOptions {optBounds = budgeted (Just 10) defaultBounds}
    task ← admit rig "task" OrdinaryClass Looped
    script rig "task" [writeIORef (rigClockHook rig) (ioError (userError "clock down")) >> yielded "task"]
    outcome ← try @SomeException (turn rig)
    either (const (pure ())) (const (fail "the turn should have failed")) outcome
    -- The segment had returned and its report was applied before the clock was
    -- read, so the task is ready, not running, and the stop closes it.
    phase rig task >>= (`shouldBe` Just PhaseReady)
    writeIORef (rigClockHook rig) (pure ())
    _ ← stopScheduler (rigScheduler rig) (rigHost rig)
    map fst <$> closedTasks rig >>= (`shouldBe` [task])

  it "keeps a continuation that waits for elapsed time closable when the clock fails before its deadline can be placed" $ do
    rig ← newRig
    task ← admit rig "task" OrdinaryClass Looped
    script rig "task" [writeIORef (rigClockHook rig) (ioError (userError "clock down")) >> waitFor "task" 100]
    outcome ← try @SomeException (turn rig)
    either (const (pure ())) (const (fail "the turn should have failed")) outcome
    writeIORef (rigClockHook rig) (pure ())
    phase rig task >>= (`shouldBe` Just PhaseReady)
    _ ← stopScheduler (rigScheduler rig) (rigHost rig)
    map fst <$> closedTasks rig >>= (`shouldBe` [task])

  it "looks at the clock again after the work at a boundary, which can use up the budget" $ do
    rig ← newRigWith defaultOptions {optBounds = budgeted (Just 10) defaultBounds}
    a ← admit rig "a" OrdinaryClass Looped
    _ ← admit rig "b" OrdinaryClass Looped
    script rig "a" (repeat (cost rig 1 (yielded "a")))
    script rig "b" (repeat (cost rig 1 (yielded "b")))
    -- Closing a stopped task's continuation takes the rest of the budget.
    writeIORef (rigCloseHook rig) (\_ → advanceClock rig 100)
    cell ← newIORef Nothing
    script
      rig
      "a"
      ( ( do
            atomically (requestControl (rigScheduler rig) a RequestStop) >>= \case
              ControlAccepted accepted → writeIORef cell (Just accepted)
              other → fail ("not accepted: " <> show other)
            cost rig 1 (yielded "a")
        )
          : repeat (cost rig 1 (yielded "a"))
      )
    report ← turn rig
    -- The first segment returned at 1, inside the budget; the boundary closed the
    -- task it asked to stop and the clock reached 101; no second segment started.
    (turnSegments report, turnEnd report) `shouldBe` (1, TurnBudgetExpired)
    ran rig >>= (`shouldBe` ["a"])
    readIORef cell >>= maybe (fail "no request") (\accepted → atomically (pollControl accepted) >>= (`shouldSatisfy` \case Just (ControlSettlement ControlApplied (Just CloseClean)) → True; _ → False))

  it "leaves the pass as the next choice would when a cutoff coincides with the owner becoming idle" $ do
    let order budget = do
          rig ← newRigWith defaultOptions {optBounds = budgeted budget defaultBounds}
          forM_ [("control", ControlClass), ("ordinary", OrdinaryClass), ("background", BackgroundClass)] $ \(name, serviceClass) → do
            _ ← admit rig name serviceClass OneShot
            script rig name [cost rig 10 (waitTicks name 1)]
          _ ← turn rig
          _ ← granted rig 1
          _ ← turnsUntilIdle rig 5
          ran rig
    -- With a budget of 30 the first turn is cut exactly as the last task waits and
    -- nothing is left ready; the pass must start afresh, as it does without a
    -- budget, so that the next grant serves control, ordinary, background.
    unbudgeted ← order Nothing
    budgetedOrder ← order (Just 30)
    budgetedOrder `shouldBe` unbudgeted
    unbudgeted `shouldBe` ["control", "ordinary", "background", "control", "ordinary", "background"]

  it "never changes where the pass is: a cutoff continues the same pass, with the quanta it had left" $ do
    let quanta = Quanta (Quantum 2) (Quantum 3) (Quantum 2)
        work budget = do
          rig ← newRigWith defaultOptions {optBounds = (budgeted budget defaultBounds) {boundQuanta = quanta}}
          forM_ [("control", ControlClass), ("ordinary-1", OrdinaryClass), ("ordinary-2", OrdinaryClass), ("background", BackgroundClass)] $
            \(name, serviceClass) → admit rig name serviceClass Looped >> script rig name (repeat (cost rig 10 (yielded name)))
          runSegments rig 40
    baseline ← work Nothing
    -- One full pass, then the next pass picks the ordinary class up where its
    -- round-robin left it.
    take 14 baseline
      `shouldBe` ["control", "control", "ordinary-1", "ordinary-2", "ordinary-1", "background", "background"]
        <> ["control", "control", "ordinary-2", "ordinary-1", "ordinary-2", "background", "background"]
    -- Cut at every boundary from after each segment to after seven.
    forM_ [10, 20, 30, 50, 70] $ \budget → do
      cut ← work (Just budget)
      (budget, cut) `shouldBe` (budget, baseline)

  it "ends each turn after one segment when the budget is smaller than a segment, and still makes progress" $ do
    rig ← newRigWith defaultOptions {optBounds = budgeted (Just 1) defaultBounds}
    forM_ ["a", "b"] $ \name → admit rig name OrdinaryClass Looped >> script rig name (repeat (cost rig 100 (yielded name)))
    reports ← forM [1 ∷ Int .. 4] (const (turn rig))
    map turnSegments reports `shouldBe` [1, 1, 1, 1]
    map turnEnd reports `shouldBe` replicate 4 TurnBudgetExpired
    ran rig >>= (`shouldBe` ["a", "b", "a", "b"])

  it "serves control requests at the boundary where the budget expired, before the turn ends" $ do
    rig ← newRigWith defaultOptions {optBounds = budgeted (Just 10) defaultBounds}
    _ ← admit rig "a" OrdinaryClass Looped
    victim ← admit rig "b" OrdinaryClass Looped
    cell ← newIORef Nothing
    script
      rig
      "a"
      ( ( do
            atomically (requestControl (rigScheduler rig) victim RequestPause) >>= \case
              ControlAccepted accepted → writeIORef cell (Just accepted)
              other → fail ("not accepted: " <> show (answer other))
            cost rig 100 (yielded "a")
        )
          : repeat (cost rig 100 (yielded "a"))
      )
    script rig "b" (repeat (cost rig 100 (yielded "b")))
    report ← turn rig
    -- The segment that asked for the pause overran the budget, and the pause was
    -- applied at the boundary after it, before the turn returned and before any
    -- segment of the next one: "b" has not run at all.
    (turnSegments report, turnEnd report) `shouldBe` (1, TurnBudgetExpired)
    ran rig >>= (`shouldBe` ["a"])
    phase rig victim >>= (`shouldBe` Just PhasePaused)
    readIORef cell >>= \case
      Just accepted → atomically (pollControl accepted) >>= (`shouldSatisfy` \case Just (ControlSettlement ControlApplied Nothing) → True; _ → False)
      Nothing → fail "the request was not made"

  it "counts an overrun against its owner, kind and entry point, and not a segment that ends at the deadline" $ do
    rig ← newRigWith defaultOptions {optBounds = budgeted (Just 10) defaultBounds}
    _ ← admitSpec rig (taskSpec "slow-once" OrdinaryClass OneShot) {specEntry = "render.once"}
    _ ← admitSpec rig (taskSpec "slow-loop" OrdinaryClass Looped) {specEntry = "render.loop"}
    script rig "slow-once" [cost rig 50 (yielded "slow-once"), cost rig 50 (yielded "slow-once"), cost rig 50 (completed "slow-once")]
    script rig "slow-loop" [cost rig 50 (yielded "slow-loop"), cost rig 50 (completed "slow-loop")]
    _ ← turnsUntilIdle rig 20
    counts ← diagnostics rig
    diagOverruns counts `shouldBe` 5
    diagOverrunSites counts
      `shouldBe` [ Overrun "test-owner" Looped "render.loop" 2
                 , Overrun "test-owner" OneShot "render.once" 3
                 ]
    exact ← newRigWith defaultOptions {optBounds = budgeted (Just 10) defaultBounds}
    _ ← admit exact "exact" OrdinaryClass OneShot
    script exact "exact" [cost exact 10 (completed "exact")]
    _ ← turn exact
    diagOverruns <$> diagnostics exact >>= (`shouldBe` 0)
    past ← newRigWith defaultOptions {optBounds = budgeted (Just 10) defaultBounds}
    _ ← admit past "past" OrdinaryClass OneShot
    script past "past" [cost past 11 (completed "past")]
    _ ← turn past
    diagOverruns <$> diagnostics past >>= (`shouldBe` 1)

  it "bounds the sites it attributes: an overrun of a site that finds the table full is counted and not attributed" $ do
    rig ←
      newRigWith
        defaultOptions
          { optBounds = (budgeted (Just 10) defaultBounds) {boundActiveTasks = 64, boundQueuedAdmissions = 64, boundRetainedResults = 64}
          }
    forM_ [1 .. maxOverrunSites + 1] $ \n → do
      let name = Text.pack ("entry-" <> show n)
      _ ← admitSpec rig (taskSpec name OrdinaryClass OneShot)
      script rig name [cost rig 50 (completed name)]
    _ ← turnsUntilIdle rig 100
    counts ← diagnostics rig
    diagOverruns counts `shouldBe` maxOverrunSites + 1
    length (diagOverrunSites counts) `shouldBe` maxOverrunSites
    diagOverrunsUnattributed counts `shouldBe` 1
  where
    answer = \case
      ControlAccepted _ → "accepted" ∷ String
      ControlFull → "full"
      ControlClosed → "closed"
      ControlUnknownTarget → "unknown"
