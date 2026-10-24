-- | What a boundary does with the gates an example holds callbacks at when the example
-- fails: it lets them go on, so that the example ends with its own failure and not with a
-- hang in the protected teardown that waits for the callbacks they hold.
module Test.LuaRuntime.Gates (spec) where

import Control.Concurrent (forkIO, killThread, threadDelay)
import Control.Concurrent.MVar (MVar, newEmptyMVar, readMVar, takeMVar, tryPutMVar, tryReadMVar)
import Control.Exception (ExceptionWithContext (ExceptionWithContext), SomeException, finally, throwIO, try)
import Control.Monad (forM_, forever, void)
import Data.List (isInfixOf)
import Hetoimasia.Scripting.Lua.Runtime (ownerEndpoint)
import Hetoimasia.Scripting.Lua.Value
import Test.HUnit.Lang (FailureReason (Reason), HUnitFailure (HUnitFailure))
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
      Right _ → failExample "the failure of the body was lost"

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
            failExample "the call settled without the gate being opened"
        )
    case ended of
      Left (ExceptionWithContext _ raised) → raised `shouldSatisfy` brokenIs "helper"
      Right _ → failExample "the failure of the helper was lost"

  it "fails an example that returned only because its bound had opened its gates, and does not let it pass" $ bounded $ do
    gate' ← newEmptyMVar
    -- The gates are opened at a tenth of a second, the example's own limit is a minute: it returns
    -- as soon as they are open, long before the limit, and must fail all the same.
    outcome ← try @HUnitFailure . boundedAfter 100000 (60 * 1000 * 1000) $
      withBoundaryOpening [void (tryPutMVar gate' ())] $ \_ _ → readMVar gate'
    outcome `shouldSatisfy` either (const True) (const False)

  it "fails an example whose bound expired inside a protected wait that took the interruption, and that then waits for what nothing will provide, and does not hang" $ bounded $ do
    absorbed ← newEmptyMVar
    released ← newEmptyMVar
    nothing ← newEmptyMVar @()
    -- Something that could still put what the example waits for, so that the wait is not
    -- found blocked for good and ended by the runtime: it is the bound that must end it.
    keeper ← forkIO (forever (tryReadMVar nothing >> threadDelay 50000))
    -- The gates are let go once the protected wait has taken the interruption, as the script
    -- runner's retirement is let go by the bound's openers; the example then fails the way a
    -- retirement does (with its own failure, the interruption absorbed), and waits for what a
    -- stopped helper was to hand over.
    outcome ←
      ( try @HUnitFailure . boundedAfter 100000 100000 $
          withBoundaryOpening [readMVar absorbed >> void (tryPutMVar released ())] $ \_ _ → do
            ExceptionWithContext _ primary ←
              tryExpected (protectedWait absorbed released >> throwIO (Broken "primary"))
                >>= either pure (\_ → failExample "the protected wait did not raise its failure")
            primary `shouldSatisfy` brokenIs "primary"
            takeMVar nothing
      )
        `finally` killThread keeper
    outcome `shouldSatisfy` either expired (const False)

  it "reports the failure an example raised itself once its gates were opened, with the bound's expiry and not in its place" $ bounded $ do
    gate' ← newEmptyMVar
    outcome ← try @HUnitFailure . boundedAfter 100000 (60 * 1000 * 1000) $
      withBoundaryOpening [void (tryPutMVar gate' ())] $ \_ _ → readMVar gate' >> failExample "its own failure"
    outcome `shouldSatisfy` either (\failure → expired failure && reasonOf failure "its own failure") (const False)

-- | A wait that nothing but its release ends: it takes every interruption and carries on, and
-- says so the first time.
protectedWait ∷ MVar () → MVar () → IO ()
protectedWait absorbed released = loop
  where
    loop = try @SomeException (readMVar released) >>= either (\_ → void (tryPutMVar absorbed ()) >> loop) pure

-- | The failure is the bound's expiry.
expired ∷ HUnitFailure → Bool
expired failure = reasonOf failure boundExpiredMessage

reasonOf ∷ HUnitFailure → String → Bool
reasonOf (HUnitFailure _ (Reason message)) text = text `isInfixOf` message
reasonOf _ _ = False
