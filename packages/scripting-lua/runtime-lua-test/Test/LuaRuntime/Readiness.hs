-- | Readiness: when creation returns, and what it does when initialization
-- does not finish.
--
-- Readiness is the body's, after the VM is constructed, its bindings installed,
-- its chunks run and its modules loaded. It is awaited through a supervised
-- wait composed with the worker's own outcome, so the startup acknowledgement
-- `startSupervised` waits for is not mistaken for it and a failed initializer
-- cannot leave a creator waiting.
module Test.LuaRuntime.Readiness (spec) where

import Control.Concurrent (forkIO, myThreadId)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Concurrent.STM (atomically)
import Control.Exception (AsyncException (ThreadKilled), ExceptionWithContext (ExceptionWithContext), SomeException, fromException, throwIO, throwTo, try)
import Data.Text (Text)
import qualified Data.Text.Encoding as Text
import Hetoimasia.Foundation.Worker (GroupStatus (statusOutstanding), OutstandingWorker (outstandingAcknowledged))
import Hetoimasia.Runtime.Supervision (workerGroupStatus)
import Hetoimasia.Scripting.Lua.Owner
import Hetoimasia.Scripting.Lua.Runtime
import Hetoimasia.Scripting.Lua.Value (Value (VInteger))
import Test.HUnit.Lang (HUnitFailure)
import Test.Hspec (Spec, describe, it, shouldBe, shouldSatisfy)
import Test.LuaRuntime.Support

-- | A module whose load records that it loaded and then waits on a gate.
loader ∷ ModuleSource
loader =
  ModuleSource
    (ModuleRef "loader" "1")
    (Text.encodeUtf8 "app.note('loaded') app.block('load')")
    []

-- | A module whose load fails.
failingModule ∷ ModuleSource
failingModule = ModuleSource (ModuleRef "failing" "1") (Text.encodeUtf8 "error('load failed')") []

-- | A module that does not define an entry point it declares required.
incompleteModule ∷ ModuleSource
incompleteModule =
  ModuleSource
    (ModuleRef "incomplete" "1")
    (Text.encodeUtf8 "x = 1")
    [EntryPoint "missing" Required [] []]

spec ∷ Spec
spec = describe "readiness" $ do
  it "is observed only after a configured module has loaded, by a module whose load records it" $ bounded $ do
    fixture ← newFixture
    withBoundaryOpening [openAllGates fixture] $ \_ runtime → do
      creator ← myThreadId
      observed ← newEmptyMVar
      alongsideOpening
        [openAllGates fixture]
        ( do
            awaitEntered fixture "load"
            -- The module has loaded far enough to record itself, and creation has
            -- not returned: its thread is parked in the supervised wait.
            awaitBlockedOnSTM creator
            noted fixture >>= putMVar observed
            releaseGate fixture "load"
        )
        ( do
            owner ← startOwner runtime (withModules [loader] (quickSpec fixture "loading" ["app"]))
            takeMVar observed >>= (`shouldBe` ["loaded"])
            noted fixture >>= (`shouldBe` ["loaded"])
            retireOwner owner
        )

  it "fails creation, with nobody left waiting, for a failing initial chunk" $ bounded $ do
    fixture ← newFixture
    let failing = withChunks [(chunkName "init", Text.encodeUtf8 "error('init failed')")] (quickSpec fixture "chunk" ["app"])
    ExceptionWithContext _ failure ← expectFatal (\_ runtime → startLuaOwner runtime failing)
    (fromException failure ∷ Maybe LuaFault) `shouldSatisfy` isJustFault

  it "fails creation, with nobody left waiting, for a failing configured module load" $ bounded $ do
    fixture ← newFixture
    ExceptionWithContext _ failure ←
      expectFatal (\_ runtime → startLuaOwner runtime (withModules [failingModule] (quickSpec fixture "module" ["app"])))
    (fromException failure ∷ Maybe BoundaryFault) `shouldSatisfy` reasonIs (\case ScriptFailed _ _ → True; _ → False)
    ExceptionWithContext _ missing ←
      expectFatal (\_ runtime → startLuaOwner runtime (withModules [incompleteModule] (quickSpec fixture "module" ["app"])))
    (fromException missing ∷ Maybe BoundaryFault) `shouldSatisfy` reasonIs (\case EntryMissing _ → True; _ → False)

  it "fails creation, with nobody left waiting, for an unknown policy namespace" $ bounded $ do
    fixture ← newFixture
    ExceptionWithContext _ failure ←
      expectFatal (\_ runtime → startLuaOwner runtime (quickSpec fixture "policy" ["nowhere"]))
    (fromException failure ∷ Maybe BoundaryFault) `shouldSatisfy` reasonIs (== PolicyUnknownNamespace "nowhere")

  it "ends creation of an optional owner whose failure is recognized as unavailable, and the run goes on" $ bounded $ do
    fixture ← newFixture
    let everything = const True
        recognized ∷ Text → OwnerSpec → OwnerSpec
        recognized _ spec' = spec' {ownerPolicy = optionalPolicy everything}
    withBoundary $ \_ runtime → do
      chunkFailure ←
        startLuaOwner runtime . recognized "" $
          withChunks [(chunkName "init", Text.encodeUtf8 "error('init failed')")] (quickSpec fixture "chunk" ["app"])
      moduleFailure ← startLuaOwner runtime (recognized "" (withModules [failingModule] (quickSpec fixture "module" ["app"])))
      policyFailure ← startLuaOwner runtime (recognized "" (quickSpec fixture "policy" ["nowhere"]))
      let unavailable = \case
            OwnerUnavailable (ExceptionWithContext _ failure) → Just failure
            _ → Nothing
      fmap (fromException @LuaFault) (unavailable chunkFailure) `shouldSatisfy` maybe False isJustFault
      fmap (fromException @BoundaryFault) (unavailable moduleFailure) `shouldSatisfy` maybe False (reasonIs (\case ScriptFailed _ _ → True; _ → False))
      fmap (fromException @BoundaryFault) (unavailable policyFailure) `shouldSatisfy` maybe False (reasonIs (== PolicyUnknownNamespace "nowhere"))
      -- The group is still usable: a healthy owner is created and serves.
      owner ← startOwner runtime (quickSpec fixture "healthy" ["app"])
      ticket ← submit (ownerEndpoint owner) "echo" [VInteger 1] >>= accepted
      returnedValues <$> settleOutcome ticket >>= (`shouldBe` Just [VInteger 1])
      retireOwner owner

  it "does not mistake the startup acknowledgement for readiness" $ bounded $ do
    fixture ← newFixture
    withBoundaryOpening [openAllGates fixture] $ \control runtime → do
      creator ← myThreadId
      observed ← newEmptyMVar
      alongsideOpening
        [openAllGates fixture]
        ( do
            awaitEntered fixture "init"
            awaitBlockedOnSTM creator
            -- The worker is acknowledged, the chunk is still running, and creation
            -- has not returned.
            status ← atomically (workerGroupStatus control)
            putMVar observed (map outstandingAcknowledged (statusOutstanding status))
            releaseGate fixture "init"
        )
        ( do
            owner ←
              startOwner runtime $
                withChunks [(chunkName "slow", Text.encodeUtf8 "app.block('init')")] (quickSpec fixture "slow" ["app"])
            takeMVar observed >>= (`shouldBe` [True])
            retireOwner owner
        )

  it "leaves an abandoned creation owned, stopped and drained by the boundary" $ bounded $ do
    fixture ← newFixture
    outcome ← newEmptyMVar
    withBoundaryOpening [openAllGates fixture] $ \_ runtime → do
      creator ←
        forkIO $
          try @SomeException
            ( startOwner runtime $
                withChunks
                  [gcInitChunk "closed", (chunkName "slow", Text.encodeUtf8 "app.block('init')")]
                  (quickSpec fixture "abandoned" ["app"])
            )
            >>= putMVar outcome . either Just (const Nothing)
      awaitEntered fixture "init"
      -- The startup was acknowledged, so a creator parked in an STM wait is
      -- parked in the readiness wait.
      awaitBlockedOnSTM creator
      throwTo creator ThreadKilled
      -- The creator ends with the exception thrown to it; a failed assertion it raised first is not that.
      takeMVar outcome >>= \case
        Just failure | Just (assertion ∷ HUnitFailure) ← fromException failure → throwIO assertion
        ended → ended `shouldSatisfy` maybe False ((== Just ThreadKilled) . fromException)
      releaseGate fixture "init"
      -- The adapter asked the owner to stop, so with its initialization done it
      -- stops and closes its VM, which its finalizer says, while the boundary
      -- is still open.
      awaitEntered fixture "closed"
    -- The boundary then returned without a failure: the worker was drained.
    noted fixture >>= (`shouldBe` ["gc closed"])
  where
    isJustFault = maybe False (const True)
    reasonIs holds = maybe False (holds . boundaryReason)
