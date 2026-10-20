-- | Waits from callbacks and tick completion (requirements 14 and 15 of the
-- marker): every public blocking wait is refused from inside a Lua callback,
-- including one built outside it, scheduled-owner creation included; and a wait
-- for tick completion ends when the owner exits, without completing the tick.
module Test.LuaRuntime.Scheduled.Callbacks (spec) where

import Control.Concurrent (forkIO)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Monad (forM_, void)
import Data.IORef (modifyIORef', readIORef, writeIORef)
import qualified Data.Map.Strict as Map
import Hetoimasia.Scripting.Lua.Scheduled
import Hetoimasia.Scripting.Lua.Value (Value (VBoolean, VInteger, VText))
import Test.Hspec (Spec, describe, it, shouldBe)
import Test.LuaRuntime.Scheduled.Support
import Test.LuaRuntime.Scheduler.Support (nanoseconds)
import Test.LuaRuntime.Support (bounded, brokenIs, failExample, Gated (..), optionalPolicy, requiredPolicy, withBoundary, withBoundaryOpening)

spec ∷ Spec
spec = describe "waits from callbacks and tick completion" $ do
  it "refuses every blocking wait from inside a Lua callback, one built outside it and scheduled-owner creation included" $ bounded $ do
    fixture ← newSFixture
    withBoundary $ \control runtime → do
      owner ← startScheduled fixture runtime (scheduled fixture "probes" requiredPolicy defaultSchedulerBounds)
      writeIORef (sfRuntime fixture) (Just runtime)
      writeIORef (sfSupervision fixture) (Just control)
      writeIORef (sfOwner fixture) (Just owner)
      done ← admitTask' fixture owner "done" (request "echo" [VInteger 1] OrdinaryClass OneShot Nothing)
      _ ← outcomeOf done
      target ← admitTask' fixture owner "target" (request "forever" [VText "x"] OrdinaryClass Looped Nothing)
      receipt ←
        requestTaskControl (scheduledEndpoint owner) (ticketTask target) RequestPause >>= \case
          TaskControlAccepted held → pure held
          other → failExample ("the request was not accepted: " <> show other)
      modifyIORef' (sfTickets fixture) (Map.insert "done" done)
      modifyIORef' (sfReceipts fixture) (Map.insert "receipt" receipt)
      -- Built outside any callback, run inside one.
      writeIORef (sfPrebuilt fixture) (void (waitTask done))
      forM_ [("wait_task", "done"), ("await_task", "done"), ("wait_control", "receipt"), ("await_control", "receipt"), ("await_ticks", ""), ("start", ""), ("prebuilt", "")] $ \(kind, name) → do
        probing ← admitTask' fixture owner ("probe " <> kind) (request "probe" [VText kind, VText name] OrdinaryClass OneShot Nothing)
        outcomeOf probing >>= (`shouldBe` Just [VBoolean True]) . taskReturned
      readIORef (sfProbe fixture)
        >>= (`shouldBe` reverse ["wait-task", "await-task", "wait-control", "await-control", "await-ticks-complete", "start-scheduled-owner", "wait-task"])
      retireScheduled owner

  describe "waiting for tick completion" $ do
    it "ends with the owner when it stops with a tick outstanding, and never reports the tick completed" $ bounded $ do
      fixture ← newSFixture
      withBoundaryOpening [openAllGates fixture] $ \control runtime → do
        owner ← startScheduled fixture runtime (scheduled fixture "ticks" requiredPolicy defaultSchedulerBounds)
        _ ← admitTask' fixture owner "w" (request "wait_ticks" [VText "w", VInteger 1] OrdinaryClass OneShot (Just "w"))
        awaitDiagnostics owner (\counts → diagWaiting counts >= 1)
        result ← newEmptyMVar
        _ ←
          holding fixture owner $ do
            -- A grant the owner has not applied, because it is held in a segment, and
            -- a stop that is requested before it is let go. The grant is applied at
            -- the next boundary and wakes the task, which the stop is then noticed
            -- before: the tick is not finished when the owner exits.
            _ ← grantScheduledStep (scheduledEndpoint owner) (nanoseconds 5)
            _ ← forkIO (awaitTicksComplete control owner >>= putMVar result)
            retireScheduled owner
        takeMVar result >>= (`shouldBe` TickOwnerEnded)

    it "ends with an owner that failed recognizably with a tick outstanding, the other owner untouched" $ bounded $ do
      fixture ← newSFixture
      withBoundary $ \control runtime → do
        victim ← startScheduled fixture runtime (scheduled fixture "victim" (optionalPolicy (brokenIs "bang")) defaultSchedulerBounds)
        bystander ← startScheduled fixture runtime (scheduled fixture "bystander" requiredPolicy defaultSchedulerBounds)
        _ ← admitTask' fixture victim "bang" (request "tick_then_fail" [VText "bang"] OrdinaryClass OneShot Nothing)
        awaitDiagnostics victim (\counts → diagWaiting counts >= 1)
        -- The grant wakes the task, which fails before it finishes the work the
        -- grant made due.
        _ ← grantScheduledStep (scheduledEndpoint victim) (nanoseconds 5)
        awaitTicksComplete control victim >>= (`shouldBe` TickOwnerEnded)
        ticket ← admitTask' fixture bystander "echo" (request "echo" [VInteger 3] OrdinaryClass OneShot Nothing)
        outcomeOf ticket >>= (`shouldBe` Just [VInteger 3]) . taskReturned
        retireScheduled bystander
