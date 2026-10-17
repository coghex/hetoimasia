-- | The same logical inputs give the same order of invocations and of recorded
-- effects, however long segments take and wherever turns are cut.
--
-- It holds for logical-time workloads: an elapsed wait legitimately changes
-- readiness, and these examples wait for no deadline.
module Test.LuaRuntime.Instance.Determinism (spec) where

import Control.Monad (forM_)
import Data.IORef (writeIORef)
import Data.Text (Text)
import Hetoimasia.Scripting.Lua.Instance (InstancePhase (Active))
import Hetoimasia.Scripting.Lua.Scheduled
import Test.Hspec (Spec, describe, it, shouldBe)
import Test.LuaRuntime.Instance.Support
import Test.LuaRuntime.Scheduled.Support (SFixture (sfDelay), awaitEffect, defaultSchedulerBounds)
import Test.LuaRuntime.Scheduler.Support (nanoseconds)
import Test.LuaRuntime.Support (bounded, requiredPolicy, withBoundary)

-- | Two instances fed the same events while the owner is held, the owner then let
-- go, and what their callbacks recorded. Each segment costs this much of the
-- injected clock, and a turn is cut by this service budget.
run ∷ Word → Maybe Word → IO [Text]
run cost budget = do
  fixture ← newIFixture
  writeIORef (sfDelay (sf fixture)) (fromIntegral cost)
  withBoundary' fixture $ \owner → do
    _ ← admit fixture owner "a" (moduleNamed "paced")
    _ ← admit fixture owner "b" (moduleNamed "paced")
    awaitPhase fixture owner "a" Active
    awaitPhase fixture owner "b" Active
    holdOwner fixture owner
    forM_ [1, 2, 3] $ \n → do
      expectDelivered fixture owner "a" n
      expectDelivered fixture owner "b" n
    releaseOwner fixture
    awaitEffect (sf fixture) "end 2 3"
    logged fixture
  where
    withBoundary' fixture body =
      withBoundary $ \_ runtime → do
        let bounds = defaultSchedulerBounds {boundServiceBudget = nanoseconds . fromIntegral <$> budget}
        owner ← startWith fixture runtime (instanceSpec fixture "deterministic" [paced, holder] (testConfig instanceBounds') requiredPolicy bounds)
        body owner

spec ∷ Spec
spec = describe "determinism" $ do
  it "orders invocations and effects by the logical inputs alone, whatever segments cost and wherever the service budget cuts a turn" $ bounded $ do
    baseline ← run 0 Nothing
    -- First in, first out, yielding to the tail: the instances take turns.
    baseline
      `shouldBe` [ "begin 1 1"
                 , "begin 2 1"
                 , "end 1 1"
                 , "end 2 1"
                 , "begin 1 2"
                 , "begin 2 2"
                 , "end 1 2"
                 , "end 2 2"
                 , "begin 1 3"
                 , "begin 2 3"
                 , "end 1 3"
                 , "end 2 3"
                 ]
    -- Every segment overruns a one-nanosecond budget, so every turn is cut after one.
    run 5 (Just 1) >>= (`shouldBe` baseline)
    -- Segments of different lengths against a budget that cuts some turns and not others.
    run 3 (Just 5) >>= (`shouldBe` baseline)
    run 1000 (Just 2500) >>= (`shouldBe` baseline)
    run 7 Nothing >>= (`shouldBe` baseline)
