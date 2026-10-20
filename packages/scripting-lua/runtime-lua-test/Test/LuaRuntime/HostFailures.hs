-- | Host failures: what the application's own code raises ends the owner,
-- unconverted, and what follows is the owner's policy.
module Test.LuaRuntime.HostFailures (spec) where

import Control.Concurrent.STM (atomically)
import Control.Exception (ExceptionWithContext (ExceptionWithContext), fromException)
import Control.Monad (forM, forM_)
import Data.IORef (writeIORef)
import Data.ByteString (ByteString)
import qualified Data.Text.Encoding as Text
import Hetoimasia.Foundation.Resource (cleanupFailureLabel, cleanupFailuresInContext)
import Hetoimasia.Runtime.Supervision (WorkerStatus (WorkerStopped, WorkerUnavailable))
import Hetoimasia.Scripting.Lua.Owner
import Hetoimasia.Scripting.Lua.Runtime
import Hetoimasia.Scripting.Lua.Value
import Test.Hspec (Spec, describe, it, shouldBe, shouldSatisfy)
import Test.LuaRuntime.Support

-- | An initial chunk whose object's finalizer fails when the VM closes.
failingGcChunk ∷ (ChunkName, ByteString)
failingGcChunk =
  ( chunkName "gc-fail"
  , Text.encodeUtf8 "collectgarbage('stop') holder = setmetatable({}, {__gc = function() app.gc_fail() end})"
  )

spec ∷ Spec
spec = describe "host failures" $ do
  it "ends only an optional owner whose classifier recognizes it, as unavailable with its own type, while another owner goes on" $ bounded $ do
    fixture ← newFixture
    withBoundary $ \control runtime → do
      victim ← startOwner runtime (ownerSpec fixture "victim" ["app"] (optionalPolicy (brokenIs "binding")) (bounds 8 8))
      bystander ← startOwner runtime (quickSpec fixture "bystander" ["app", "extra"])
      failing ← submit (ownerEndpoint victim) "host_fail" [VText "binding"] >>= accepted
      awaitTerminal control victim >>= \case
        WorkerUnavailable (ExceptionWithContext _ failure) → failure `shouldSatisfy` brokenIs "binding"
        other → failExample ("expected an unavailable owner, found " <> show other)
      -- No caller received the failure: the call settled as discarded, started.
      settleOutcome failing >>= (`shouldSatisfy` isDiscard ExitFailed Started)
      -- The other owner is untouched, with its bindings as they were.
      served ← submit (ownerEndpoint bystander) "namespaces" [] >>= accepted
      returnedValues <$> settleOutcome served >>= (`shouldBe` Just [VText "app,extra"])
      retireOwner bystander

  it "is fatal, as for any worker, for the same failure in a required owner" $ bounded $ do
    fixture ← newFixture
    ExceptionWithContext _ failure ← expectFatal $ \control runtime → do
      owner ← startOwner runtime (quickSpec fixture "required" ["app"])
      _ ← submit (ownerEndpoint owner) "host_fail" [VText "binding"] >>= accepted
      awaitTerminal control owner
    failure `shouldSatisfy` brokenIs "binding"

  it "is fatal when the close failed too, even for an optional owner that recognizes the failure, with the close failure retained beside it" $ bounded $ do
    fixture ← newFixture
    ExceptionWithContext context failure ← expectFatal $ \control runtime → do
      owner ←
        startOwner runtime $
          withChunks [failingGcChunk] (ownerSpec fixture "failing close" ["app"] (optionalPolicy (const True)) (bounds 4 4))
      _ ← submit (ownerEndpoint owner) "host_fail" [VText "binding"] >>= accepted
      awaitFatal control owner
    failure `shouldSatisfy` brokenIs "binding"
    map cleanupFailureLabel (cleanupFailuresInContext context) `shouldSatisfy` elem "lua finalizer"

  it "settles the in-flight call as discarded, started, failed, and every queued call as not started, failed, and no caller receives the failure" $ bounded $ do
    fixture ← newFixture
    withBoundaryOpening [openAllGates fixture] $ \control runtime → do
      owner ← startOwner runtime (ownerSpec fixture "failing" ["app"] (optionalPolicy (brokenIs "binding")) (bounds 8 8))
      let endpoint = ownerEndpoint owner
      inflight ← submit endpoint "block_then_fail" [VText "go", VText "binding"] >>= accepted
      awaitEntered fixture "go"
      queued ← forM [1, 2 ∷ Int] $ \n → submit endpoint "echo" [VInteger (fromIntegral n)] >>= accepted
      releaseGate fixture "go"
      awaitTerminal control owner >>= \case
        WorkerUnavailable (ExceptionWithContext _ failure) → failure `shouldSatisfy` brokenIs "binding"
        other → failExample ("expected an unavailable owner, found " <> show other)
      settleOutcome inflight >>= (`shouldSatisfy` isDiscard ExitFailed Started)
      forM_ queued $ \ticket → settleOutcome ticket >>= (`shouldSatisfy` isDiscard ExitFailed NotStarted)
      Just record ← atomically (ownerExitRecord owner)
      (exitKind record, exitStarted record, exitNotStarted record) `shouldBe` (ExitFailed, 1, 2)

  it "treats a boundary fault or a Lua fault thrown by a binding's action as the host's failure, by where it was raised and not by its type" $ bounded $ do
    fixture ← newFixture
    withBoundary $ \control runtime → do
      let recognizesAll = optionalPolicy (const True)
          failureOf' = \case
            WorkerUnavailable (ExceptionWithContext _ failure) → Just failure
            _ → Nothing
      boundary ← startOwner runtime (ownerSpec fixture "boundary" ["app"] recognizesAll (bounds 4 4))
      lua ← startOwner runtime (ownerSpec fixture "lua" ["app"] recognizesAll (bounds 4 4))
      swallowed ← startOwner runtime (ownerSpec fixture "swallowed" ["app"] recognizesAll (bounds 4 4))
      boundaryCall ← submit (ownerEndpoint boundary) "host_fail" [VText "boundary"] >>= accepted
      luaCall ← submit (ownerEndpoint lua) "host_fail" [VText "lua"] >>= accepted
      -- A refusal of the boundary that the script caught, then a binding that fails.
      swallowedCall ← submit (ownerEndpoint swallowed) "swallow_then_fail" [VText "broken"] >>= accepted
      boundaryStatus ← awaitTerminal control boundary
      luaStatus ← awaitTerminal control lua
      swallowedStatus ← awaitTerminal control swallowed
      (fromException @BoundaryFault =<< failureOf' boundaryStatus) `shouldSatisfy` maybe False ((== "the application") . boundaryOwner)
      (fromException @LuaFault =<< failureOf' luaStatus) `shouldSatisfy` maybe False (const True)
      (failureOf' swallowedStatus) `shouldSatisfy` maybe False (brokenIs "broken")
      forM_ [boundaryCall, luaCall, swallowedCall] $ \ticket →
        settleOutcome ticket >>= (`shouldSatisfy` isDiscard ExitFailed Started)

  it "keeps the mark on a failure hidden in a lazy result or a lazy liveness answer, so it is still the host's failure" $ bounded $ do
    fixture ← newFixture
    withBoundary $ \control runtime → do
      let recognizesAll = optionalPolicy (const True)
          failureOf' = \case
            WorkerUnavailable (ExceptionWithContext _ failure) → Just failure
            _ → Nothing
      lazyBoundary ← startOwner runtime (ownerSpec fixture "lazy boundary" ["app"] recognizesAll (bounds 4 4))
      lazyLua ← startOwner runtime (ownerSpec fixture "lazy lua" ["app"] recognizesAll (bounds 4 4))
      lazyLive ← startOwner runtime (ownerSpec fixture "lazy liveness" ["app"] recognizesAll (bounds 4 4))
      boundaryCall ← submit (ownerEndpoint lazyBoundary) "fail_lazy" [VText "boundary"] >>= accepted
      luaCall ← submit (ownerEndpoint lazyLua) "fail_lazy" [VText "lua"] >>= accepted
      writeIORef (fixtureLiveFault fixture) (Just (applicationFault "liveness"))
      liveCall ← submit (ownerEndpoint lazyLive) "redeem" [VCapability (capability "ticket" 1)] >>= accepted
      boundaryStatus ← awaitTerminal control lazyBoundary
      luaStatus ← awaitTerminal control lazyLua
      liveStatus ← awaitTerminal control lazyLive
      (fromException @BoundaryFault =<< failureOf' boundaryStatus) `shouldSatisfy` maybe False ((== "the application") . boundaryOwner)
      (fromException @LuaFault =<< failureOf' luaStatus) `shouldSatisfy` maybe False (const True)
      (fromException @BoundaryFault =<< failureOf' liveStatus) `shouldSatisfy` maybe False ((== "liveness") . boundaryChunk)
      -- None of them was handed to a caller as the call's own fault.
      forM_ [boundaryCall, luaCall, liveCall] $ \ticket →
        settleOutcome ticket >>= (`shouldSatisfy` isDiscard ExitFailed Started)

  it "delivers an application's own fault to supervision as it was thrown, though the script caught it and called another binding" $ bounded $ do
    fixture ← newFixture
    withBoundary $ \control runtime → do
      owner ← startOwner runtime (ownerSpec fixture "caught" ["app"] (optionalPolicy (const True)) (bounds 4 4))
      call ← submit (ownerEndpoint owner) "catch_then_call" [VText "boundary"] >>= accepted
      awaitTerminal control owner >>= \case
        WorkerUnavailable (ExceptionWithContext _ failure) →
          -- The fault the fixture threw, effect and all: a later binding's call
          -- rewrote nothing of it.
          fromException @BoundaryFault failure `shouldBe` Just applicationBoundaryFault
        other → failExample ("expected an unavailable owner, found " <> show other)
      settleOutcome call >>= (`shouldSatisfy` isDiscard ExitFailed Started)

  it "settles a cancelled owner's in-flight call as discarded, started, cancelled, and its queued calls as not started, cancelled" $ bounded $ do
    fixture ← newFixture
    withBoundaryOpening [openAllGates fixture] $ \control runtime → do
      owner ← startOwner runtime (ownerSpec fixture "cancelled" ["app"] requiredPolicy (bounds 8 8))
      let endpoint = ownerEndpoint owner
      inflight ← submit endpoint "block_call" [VText "go"] >>= accepted
      awaitEntered fixture "go"
      queued ← forM [1, 2 ∷ Int] $ \n → submit endpoint "echo" [VInteger (fromIntegral n)] >>= accepted
      cancelOwner owner
      -- A cancellation is never delivered inside Lua: it lands when the call returns.
      releaseGate fixture "go"
      awaitTerminal control owner >>= (`shouldSatisfy` \case WorkerStopped → True; _ → False)
      settleOutcome inflight >>= (`shouldSatisfy` isDiscard ExitCancelled Started)
      forM_ queued $ \ticket → settleOutcome ticket >>= (`shouldSatisfy` isDiscard ExitCancelled NotStarted)
      Just record ← atomically (ownerExitRecord owner)
      (exitKind record, exitStarted record, exitNotStarted record) `shouldBe` (ExitCancelled, 1, 2)
