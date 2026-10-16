-- | Stop and retire: admission closes at once, the in-flight call returns with
-- its own settlement, queued calls are discarded and counted, the VM closes
-- last, and nothing is detached while a call is stuck.
module Test.LuaRuntime.Stop (spec) where

import Control.Concurrent.STM (atomically)
import Control.Monad (forM, forM_, replicateM)
import Data.Maybe (isJust, isNothing)
import Hetoimasia.Foundation.Worker (GroupStatus (statusOutstanding))
import Hetoimasia.Runtime.Supervision
  ( WorkerStatus (WorkerLive, WorkerStopped, WorkerUnavailable)
  , workerGroupStatus
  )
import Control.Exception (ExceptionWithContext (ExceptionWithContext))
import Hetoimasia.Scripting.Lua.Owner
import Hetoimasia.Scripting.Lua.Runtime
import Hetoimasia.Scripting.Lua.Value
import Test.Hspec (Spec, describe, it, shouldBe, shouldSatisfy)
import Test.LuaRuntime.Support

spec ∷ Spec
spec = describe "stop and retire" $ do
  it "closes admission at once, lets the in-flight call return, discards the backlog as not started and stopped, and closes the VM after" $ bounded $ do
    fixture ← newFixture
    withBoundary $ \control runtime → do
      owner ←
        startOwner runtime $
          withChunks [gcInitChunk "closed"] (ownerSpec fixture "stopping" ["app"] requiredPolicy (bounds 4 10))
      let endpoint = ownerEndpoint owner
      inflight ← submit endpoint "block_call" [VText "hold"] >>= accepted
      awaitEntered fixture "hold"
      backlog ← replicateM 4 (submit endpoint "echo" [VInteger 1] >>= accepted)
      submit endpoint "echo" [VInteger 1] >>= (`shouldSatisfy` \case CallFull → True; _ → False)
      retireOwner owner
      -- The request closed admission although the thread is still held in the call.
      submit endpoint "echo" [VInteger 1] >>= (`shouldSatisfy` \case CallClosed → True; _ → False)
      -- A stuck in-flight call keeps the worker, its VM and its dependencies live.
      atomically (ownerStatus owner) >>= (`shouldSatisfy` \case WorkerLive → True; _ → False)
      status ← atomically (workerGroupStatus control)
      length (statusOutstanding status) `shouldBe` 1
      hasEntered fixture "closed" >>= (`shouldBe` False)
      atomically (ownerExitRecord owner) >>= (`shouldSatisfy` isNothing)
      forM_ backlog $ \ticket → pollCall ticket >>= (`shouldSatisfy` isNothing)
      releaseGate fixture "hold"
      -- The in-flight call returns with its own settlement.
      returnedValues <$> settleOutcome inflight >>= (`shouldBe` Just [VInteger 1])
      outcomes ← forM backlog settleOutcome
      forM_ outcomes (`shouldSatisfy` isDiscard ExitStopped NotStarted)
      awaitTerminal control owner >>= (`shouldSatisfy` \case WorkerStopped → True; _ → False)
      Just record ← atomically (ownerExitRecord owner)
      (exitKind record, exitNotStarted record, exitStarted record) `shouldBe` (ExitStopped, 4, 0)
      -- The VM closed on the worker's thread, and after every settlement existed:
      -- a close from another thread is refused, so a finalizer that ran says so.
      awaitEntered fixture "closed"
      noted fixture >>= (`shouldBe` ["gc closed"])

  it "closes admission before the VM begins to close, so a failed owner held in a finalizer answers closed and keeps its settlements and its dependencies" $ bounded $ do
    fixture ← newFixture
    withBoundary $ \control runtime → do
      let holdsClose =
            ( chunkName "gc-block"
            , "collectgarbage('stop') holder = setmetatable({}, {__gc = function() app.gc_block('fin') end})"
            )
      owner ←
        startOwner runtime $
          withChunks [holdsClose] (ownerSpec fixture "failed" ["app"] (optionalPolicy (const True)) (bounds 8 8))
      let endpoint = ownerEndpoint owner
      inflight ← submit endpoint "block_then_fail" [VText "go", VText "binding"] >>= accepted
      awaitEntered fixture "go"
      queued ← replicateM 2 (submit endpoint "echo" [VInteger 1] >>= accepted)
      releaseGate fixture "go"
      -- The owner failed, and the VM's close is held inside a finalizer.
      awaitEntered fixture "fin"
      submit endpoint "echo" [VInteger 1] >>= (`shouldSatisfy` \case CallClosed → True; _ → False)
      atomically (ownerStatus owner) >>= (`shouldSatisfy` \case WorkerLive → True; _ → False)
      status ← atomically (workerGroupStatus control)
      length (statusOutstanding status) `shouldBe` 1
      -- Each settlement exists, and reading it again answers the same one.
      forM_ (inflight : queued) $ \ticket → do
        first ← pollCall ticket
        second ← pollCall ticket
        first `shouldSatisfy` isJust
        fmap (show . settledOutcome) first `shouldBe` fmap (show . settledOutcome) second
      Just record ← atomically (ownerExitRecord owner)
      (exitKind record, exitStarted record, exitNotStarted record) `shouldBe` (ExitFailed, 1, 2)
      releaseGate fixture "fin"
      awaitTerminal control owner >>= \case
        WorkerUnavailable (ExceptionWithContext _ failure) → failure `shouldSatisfy` brokenIs "binding"
        other → fail ("expected an unavailable owner, found " <> show other)
