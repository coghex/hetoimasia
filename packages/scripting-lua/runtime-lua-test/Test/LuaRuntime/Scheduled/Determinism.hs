-- | Determinism (requirement 17, D-23): on one scheduled owner with a fixed policy
-- and configuration, the same admitted tasks, grants and control requests, each
-- made at the same logical point (while the owner awaits the next grant), give the
-- same segments in the same order, the same logical durations to each task and the
-- same order of recorded effects, however long segments take and whether budgets
-- expire.
--
-- The workload is logical-time work only. An elapsed wait legitimately changes
-- readiness with real time, and is tested separately in "Execution".
module Test.LuaRuntime.Scheduled.Determinism (spec) where

import Control.Monad (forM_, void)
import Data.IORef (writeIORef)
import Data.Text (Text)
import Hetoimasia.Scripting.Lua.Scheduled
import Hetoimasia.Scripting.Lua.Value (Value (VInteger, VText))
import Test.Hspec (Spec, describe, it, shouldBe)
import Test.LuaRuntime.Scheduled.Support
import Test.LuaRuntime.Scheduler.Support (allRegs, nanoseconds)
import Test.LuaRuntime.Support (Gated (..), bounded, requiredPolicy, withBoundaryOpening)

-- | What one run observed.
data Observation = Observation
  { observedEffects ∷ [Text]
  , observedSegments ∷ [(Maybe Text, Int, Maybe Resume)]
  , observedRegistrations ∷ Int
  }
  deriving (Eq, Show)

-- | The workload, run once: how long each segment takes on the clock, and the
-- budget the owner is configured with, are what differ between runs.
run ∷ Word → Maybe Word → IO Observation
run delay budget = do
  fixture ← newSFixture
  writeIORef (sfDelay fixture) (fromIntegral delay)
  withBoundaryOpening [openAllGates fixture] $ \control runtime → do
    let bounds = defaultSchedulerBounds {boundServiceBudget = nanoseconds . fromIntegral <$> budget}
    owner ← startScheduled fixture runtime (scheduled fixture "deterministic" requiredPolicy bounds)
    let endpoint = scheduledEndpoint owner
        ticker label n every serviceClass kind =
          request "ticker" [VText label, VInteger n, VInteger every] serviceClass kind (Just label)
    -- Admitted together, in this order, while the owner is held.
    [_, b, _, _] ←
      holding fixture owner $
        sequence
          [ admitTask' fixture owner "A" (ticker "A" 3 1 OrdinaryClass OneShot)
          , admitTask' fixture owner "B" (ticker "B" 2 2 OrdinaryClass Looped)
          , admitTask' fixture owner "C" (request "delayed" [VText "C", VInteger 2] ControlClass OneShot (Just "C"))
          , admitTask' fixture owner "D" (ticker "D" 2 3 BackgroundClass OneShot)
          ]
    -- The owner is awaiting the first grant once C has finished and the others wait.
    awaitDiagnostics owner (\counts → diagCompleted counts >= 2 && diagWaiting counts >= 3)
    let grant n = do
          _ ← grantScheduledStep endpoint (nanoseconds n)
          awaitTicksComplete control owner >>= (`shouldBe` TicksCompleted)
        controlB request' = do
          requestTaskControl endpoint (ticketTask b) request' >>= \case
            TaskControlAccepted receipt → void (waitControl receipt)
            other → fail ("the request was not accepted: " <> show other)
    grant 3
    controlB RequestPause
    grant 5
    grant 8
    controlB RequestResume
    awaitEffect fixture "B 1 2:8"
    mapM_ grant [13, 21, 2]
    -- Every task has finished.
    awaitDiagnostics owner (\counts → diagCompleted counts >= 5)
    observation ←
      Observation
        <$> taskEffects fixture
        <*> (map (\context → (contextName context, contextSegment context, contextResume context)) <$> segmentsRun fixture)
        <*> (length <$> allRegs (sfTimer fixture))
    retireScheduled owner
    pure observation

spec ∷ Spec
spec = describe "determinism of logical-time work" $ do
  it "gives the same segments, durations and effect order whatever the segments' delays, the budget and its expiries" $ bounded $ do
    baseline ← run 0 Nothing
    observedEffects baseline
      `shouldBe` ["C1", "C2", "A 1 1:3", "A 2 2:5", "A 3 3:8", "D 1 3:16", "B 1 2:8", "B 2 5:34", "D 2 6:36"]
    -- Logical work arms no timer, so there was no wake whose timing could matter.
    observedRegistrations baseline `shouldBe` 0
    forM_ [(7, Just 5), (1000, Just 50), (3, Just 1), (500, Nothing), (50, Just 2000), (1, Just 100000)] $ \(delay, budget) → do
      varied ← run delay budget
      (delay, budget, varied) `shouldBe` (delay, budget, baseline)
