-- | What a boundary does with the gates an example holds callbacks at when the example
-- fails: it lets them go on, so that the example ends with its own failure and not with a
-- hang in the protected teardown that waits for the callbacks they hold.
module Test.LuaRuntime.Gates (spec) where

import Control.Concurrent.MVar (newEmptyMVar, readMVar, tryPutMVar, tryReadMVar)
import Control.Exception (ExceptionWithContext (ExceptionWithContext), throwIO, try)
import Control.Monad (forM_, void)
import Hetoimasia.Scripting.Lua.Runtime (ownerEndpoint)
import Hetoimasia.Scripting.Lua.Value
import Test.HUnit.Lang (HUnitFailure)
import Test.Hspec (Spec, describe, it, shouldBe, shouldSatisfy)
import Test.LuaRuntime.Support

spec ∷ Spec
spec = describe "the gates a boundary opens when an example fails" $ do
  it "lets a callback held at a gate return when the body of the boundary fails, so that the boundary ends with that failure" $ bounded $ do
    fixture ← newFixture
    ended ← tryBoundaryOpening [openAllGates fixture] $ \_ runtime → do
      owner ← startOwner runtime (quickSpec fixture "held" ["app"])
      _ ← submit (ownerEndpoint owner) "block_call" [VText "hold"] >>= accepted
      awaitEntered fixture "hold"
      throwIO (Broken "body")
    case ended of
      Left (ExceptionWithContext _ raised) → raised `shouldSatisfy` brokenIs "body"
      Right _ → fail "the failure of the body was lost"

  it "opens every gate there is, and the gate that is first named afterwards, so that a callback arriving late is let through" $ bounded $ do
    fixture ← newFixture
    _ ← gate fixture "named"
    openAllGates fixture
    forM_ ["named", "late"] $ \name →
      gate fixture name >>= tryReadMVar >>= (`shouldBe` Just ())

  it "fails an example with the failure of its helper thread, after letting go the gates that the other action is parked behind" $ bounded $ do
    fixture ← newFixture
    ended ← tryBoundaryOpening [openAllGates fixture] $ \_ runtime →
      alongsideOpening
        [openAllGates fixture]
        (awaitEntered fixture "hold" >> throwIO (Broken "helper"))
        ( do
            owner ← startOwner runtime (quickSpec fixture "parked" ["app"])
            ticket ← submit (ownerEndpoint owner) "block_call" [VText "hold"] >>= accepted
            -- Only the helper's failure opens the gate this waits behind.
            _ ← settleOutcome ticket
            fail "the call settled without the gate being opened"
        )
    case ended of
      Left (ExceptionWithContext _ raised) → raised `shouldSatisfy` brokenIs "helper"
      Right _ → fail "the failure of the helper was lost"

  it "fails an example that returned only because its bound had opened its gates, and does not let it pass" $ bounded $ do
    gate' ← newEmptyMVar
    -- The gates are opened at a tenth of a second, the example's own limit is a minute: it returns
    -- as soon as they are open, long before the limit, and must fail all the same.
    outcome ← try @HUnitFailure . boundedAfter 100000 (60 * 1000 * 1000) $
      withBoundaryOpening [void (tryPutMVar gate' ())] $ \_ _ → readMVar gate'
    outcome `shouldSatisfy` either (const True) (const False)

