-- | Service classes and quanta (requirement 5): quanta enforced per turn, a
-- yielded task behind its ready peers, waiting and paused tasks taking no turn,
-- and a quantum below one refused at creation.
module Test.LuaRuntime.Scheduler.Classes (spec) where

import Control.Concurrent.STM (atomically)
import Data.List.NonEmpty (toList)
import Data.Text (Text)
import Hetoimasia.Foundation.Time (scriptedInstant, scriptedSource, zeroDuration)
import Hetoimasia.Scripting.Lua.Scheduler
import Test.Hspec (Spec, describe, it, shouldBe)
import Test.LuaRuntime.Scheduler.Support

quantaOf ∷ Int → Int → Int → SchedulerBounds
quantaOf control ordinary background =
  defaultBounds {boundQuanta = Quanta (Quantum control) (Quantum ordinary) (Quantum background)}

spec ∷ Spec
spec = describe "service classes and quanta" $ do
  it "runs each class at most its quantum in a turn, in class order, and ends the turn when the pass does" $ do
    rig ← newRigWith defaultOptions {optBounds = quantaOf 1 2 3}
    mapM_
      (\(name, serviceClass) → admit rig name serviceClass Looped >> loop rig name)
      [("background", BackgroundClass), ("ordinary-1", OrdinaryClass), ("control", ControlClass), ("ordinary-2", OrdinaryClass)]
    first ← turn rig
    ran rig >>= (`shouldBe` ["control", "ordinary-1", "ordinary-2", "background", "background", "background"])
    (turnSegments first, turnEnd first) `shouldBe` (6, TurnPassComplete)
    _ ← turn rig
    ran rig
      >>= (`shouldBe` ["control", "ordinary-1", "ordinary-2", "background", "background", "background"] <> ["control", "ordinary-1", "ordinary-2", "background", "background", "background"])

  it "gives no task more than its class's quantum while a peer in another class is ready" $ do
    rig ← newRigWith defaultOptions {optBounds = quantaOf 2 2 2}
    mapM_
      (\(name, serviceClass) → admit rig name serviceClass Looped >> loop rig name)
      [("control", ControlClass), ("ordinary", OrdinaryClass), ("background", BackgroundClass)]
    segments ← runSegments rig 18
    let longestRun = maximum (map length (groupRuns segments))
    longestRun `shouldBe` 2

  it "serves the ready peers of a class round-robin at segment boundaries, a yielded task behind them" $ do
    rig ← newRigWith defaultOptions {optBounds = quantaOf 4 2 4}
    mapM_ (\name → admit rig name OrdinaryClass Looped >> loop rig name) ["a", "b", "c"]
    reports ← mapM (const (turn rig)) [1 ∷ Int .. 3]
    -- Three turns of two segments: the quantum is per turn, and the order carries
    -- over because a yielded task rejoined behind the peers that were ready.
    ran rig >>= (`shouldBe` ["a", "b", "c", "a", "b", "c"])
    map turnSegments reports `shouldBe` [2, 2, 2]

  it "gives waiting and paused tasks no turn" $ do
    rig ← newRig
    waiting ← admit rig "waiting" OrdinaryClass OneShot
    paused ← admit rig "paused" OrdinaryClass Looped
    _ ← admit rig "ready" OrdinaryClass Looped
    script rig "waiting" [waitTicks "waiting" 10]
    loop rig "paused"
    loop rig "ready"
    atomically (requestControl (rigScheduler rig) paused RequestPause) >>= \case
      ControlAccepted _ → pure ()
      other → fail ("the pause was not accepted: " <> show (answerName other))
    _ ← turn rig
    ran rig >>= (`shouldBe` ["waiting", "ready", "ready", "ready"])
    phase rig waiting >>= (`shouldBe` Just PhaseWaiting)
    phase rig paused >>= (`shouldBe` Just PhasePaused)
    _ ← turn rig
    ran rig >>= \segments → filter (== "paused") segments `shouldBe` []

  it "refuses a quantum below one, with every other violation, before anything starts" $ do
    timer ← newFakeTimer
    let config bounds =
          SchedulerConfig
            { schedLabel = "refused"
            , schedScope = scope
            , schedPolicy = fifoPolicy
            , schedBounds = bounds
            , schedClock = scriptedSource (pure (scriptedInstant zeroDuration))
            , schedTimer = ftBackend timer
            , schedStopRequested = pure False
            }
    let bad = (quantaOf 0 3 (-1)) {boundActiveTasks = 0, boundOutstandingGrants = 0, boundControlRequests = 0, boundServiceBudget = Just zeroDuration}
    refused ← newScheduler @() (config bad)
    case refused of
      Left (SchedulerRefused violations) →
        toList violations
          `shouldBe` [ LimitRefused (NonPositiveLimit ActiveTasks 0)
                     , LimitRefused (NonPositiveQuantum ControlClass 0)
                     , LimitRefused (NonPositiveQuantum BackgroundClass (-1))
                     , GrantBoundBelowOne 0
                     , ControlBoundBelowOne 0
                     , BudgetNotPositive
                     ]
      Right _ → fail "the configuration should have been refused"
    -- Nothing was started: no registration was ever armed.
    length <$> allRegs timer >>= (`shouldBe` 0)
    ok ← newScheduler @() (config (quantaOf 1 1 1))
    either (const False) (const True) ok `shouldBe` True
  where
    answerName = \case
      ControlAccepted _ → "accepted" ∷ String
      ControlFull → "full"
      ControlClosed → "closed"
      ControlUnknownTarget → "unknown"

-- | The runs of one name.
groupRuns ∷ [Text] → [[Text]]
groupRuns [] = []
groupRuns (x : xs) = let (same, rest) = span (== x) xs in (x : same) : groupRuns rest
