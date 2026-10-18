-- | The invariants the request service keeps on every path, one example for each way a path was
-- found to break one:
--
-- * the model is told a provider's work is over whenever its request has settled and the work
--   is known over, whichever came last, so a place is never lost to work that ended earlier;
-- * a completion is held until its place is served, not until the owner reaches the tick, so a
--   duplicate arriving between the two is still a duplicate;
-- * what is retained is what can be delivered: a result that would not fit the record a script
--   is handed is bounded before it is retained, and taking a settlement never loses it to a fault;
-- * a task whose stop has begun is not taking requests, as an instance that is stopping is not.
module Test.LuaRuntime.Request.Invariants (spec) where

import Control.Exception (ExceptionWithContext (ExceptionWithContext), finally)
import Control.Monad (void)
import qualified Data.Text as Text
import Hetoimasia.Foundation.Resource (cleanupFailureLabel, cleanupFailuresInContext)
import Hetoimasia.Scripting.Lua.Instance
import Hetoimasia.Scripting.Lua.Provider
import Hetoimasia.Scripting.Lua.Scheduled
import Hetoimasia.Scripting.Lua.Value
import Test.Hspec (Spec, describe, it, shouldBe, shouldSatisfy)
import Test.LuaRuntime.Instance.Support
import Test.LuaRuntime.Request.Support
import Test.LuaRuntime.Scheduled.Support (awaitEffect, awaitEntered, awaitScheduledTerminal, releaseGate)
import Test.LuaRuntime.Scheduler.Support (nanoseconds)
import Test.LuaRuntime.Support (bounded, expectFatal, optionalPolicy, requiredPolicy, withBoundary)

step ∷ ScheduledOwner → IO ()
step owner = void (grantScheduledStep (scheduledEndpoint owner) (nanoseconds 1))

spec ∷ Spec
spec = describe "invariants" $ do
  describe "the model is told the provider's work is over, whichever came last" $ do
    it "frees the place of a request whose held completion was followed by the instance's end, after the owner had already disposed of the work" $ bounded $ do
      fixture ← newIFixture
      fake ← newFake
      withBoundary $ \_ runtime → providersFinish fake $ do
        owner ← startRequester fixture runtime "ghost" [asker] cmdConfig (logicalGrant fake 1 Nothing) requiredPolicy
        admitAsker fixture owner "i" "asker"
        command fixture owner "i" "start" "a"
        awaitLine fixture "cmd start a started"
        answerResult fake 0 7 >>= (`shouldBe` ReplyHeld)
        -- The owner has run what the work needed, and forgotten the work, before the tick.
        awaitLine fixture "disposed 0"
        awaitDiagnostic owner ((== 0) . rdWorkPending)
        _ ← expectControl fixture owner "i" InstanceStop
        _ ← awaitSettled fixture "i"
        -- Nothing is left charged: the one place is free again.
        awaitDiagnostic owner ((== 0) . rdOutstanding)
        admitAsker fixture owner "j" "asker"
        command fixture owner "j" "start" "b"
        awaitLine fixture "cmd start b started"

  describe "a completion is held until its place is served" $ do
    it "keeps the first value against a duplicate that arrives after the tick was applied and before its settlements were served" $ bounded $ do
      fixture ← newIFixture
      fake ← newFake
      withBoundary $ \control runtime → providersFinish fake $ do
        owner ← startRequester fixture runtime "window" [asker] cmdConfig (logicalGrant fake 8 Nothing) requiredPolicy
        admitAsker fixture owner "i" "asker"
        (do
            command fixture owner "i" "start" "a"
            awaitLine fixture "cmd start a started"
            ticket ← taskOf owner "close_block" [VText "path", VInteger 5]
            awaitSubmitted fake 2
            awaitLine fixture "task started 5"
            -- The owner is held in Lua while the grant, the task's stop and both completions
            -- are accepted, so that all of them are found together at the next boundary.
            command fixture owner "i" "block" "g1"
            awaitEntered (sf fixture) "g1"
            step owner
            _ ← requestTaskControl (scheduledEndpoint owner) (ticketTask ticket) RequestStop
            answerResult fake 0 7 >>= (`shouldBe` ReplyHeld)
            answerResult fake 1 3 >>= (`shouldBe` ReplyHeld)
            releaseGate (sf fixture) "g1"
            -- The grant is applied, then the stop, and the task's closing handler holds the
            -- owner before the tick's places are served.
            awaitEntered (sf fixture) "upd"
            tickReached owner >>= (`shouldBe` 1)
            answerResult fake 0 9 >>= (`shouldBe` ReplyLate)
            rdDuplicateHeld <$> diagnostics owner >>= (`shouldBe` 1)
            releaseGate (sf fixture) "upd"
            _ ← awaitTicksComplete control owner
            command fixture owner "i" "take" "a"
            awaitLine fixture "cmd take a {status=result,value=7}"
          )
          `finally` (releaseGate (sf fixture) "g1" >> releaseGate (sf fixture) "upd")

  describe "what is retained can be delivered" $ do
    it "bounds a result with the record a script is handed counted, so one that would not fit is a failure when it arrives" $ bounded $ do
      fixture ← newIFixture
      fake ← newFake
      withBoundary $ \_ runtime → providersFinish fake $ do
        owner ← startRequesterWith fixture runtime (smallLimits (requestSpec fixture "edge" [asker] cmdConfig (RequestGrant [fakeEndpointOf fake "text" SText] 4 SettleOnArrival) requiredPolicy))
        admitAsker fixture owner "i" "asker"
        commandFrom fixture owner "i" "start" "a" (Just "text") (Just 1)
        awaitLine fixture "cmd start a started"
        -- Within the limit bare, over it as the record a script takes.
        answerWith fake 0 (ProviderResult (VText (Text.replicate 495 "x"))) >>= (`shouldBe` ReplyRefusedValue)
        command fixture owner "i" "take" "a"
        line ← awaitTaken fixture "cmd take a "
        line `shouldSatisfy` Text.isInfixOf "status=failure"

    it "delivers a result its taking operation cannot hold as a failure that says so, and does not lose it to a fault" $ bounded $ do
      fixture ← newIFixture
      fake ← newFake
      withBoundary $ \_ runtime → providersFinish fake $ do
        -- The endpoint answers text; the taking operation declares integers.
        owner ← startRequester fixture runtime "mismatch" [asker] cmdConfig (RequestGrant [fakeEndpointOf fake "text" SText] 4 SettleOnArrival) requiredPolicy
        admitAsker fixture owner "i" "asker"
        commandFrom fixture owner "i" "start" "a" (Just "text") (Just 1)
        awaitLine fixture "cmd start a started"
        answerWith fake 0 (ProviderResult (VText "hello")) >>= (`shouldBe` ReplySettled)
        command fixture owner "i" "take" "a"
        line ← awaitTaken fixture "cmd take a "
        line `shouldSatisfy` Text.isInfixOf "status=failure"
        line `shouldSatisfy` Text.isInfixOf "could not be delivered"

  describe "a task whose stop has begun is not taking requests" $ do
    it "refuses a request made by a closing handler of a task being stopped, without asking the provider again" $ bounded $ do
      fixture ← newIFixture
      fake ← newFake
      ExceptionWithContext context _ ← expectFatal $ \control runtime → providersFinish fake $ do
        owner ← startRequester fixture runtime "task closing" [asker] cmdConfig (grantOf fake 4) (optionalPolicy (const True))
        ticket ← taskOf owner "close_ask" [VText "path", VInteger 5]
        awaitSubmitted fake 1
        awaitLine fixture "task started 5"
        _ ← requestTaskControl (scheduledEndpoint owner) (ticketTask ticket) RequestStop
        awaitCancelled fake 1
        awaitEffect (ifBase fixture) "task closing"
        submissions fake >>= (`shouldBe` 1)
        finishWork fake 0
        awaitScheduledTerminal control owner
      map cleanupFailureLabel (cleanupFailuresInContext context) `shouldSatisfy` elem "lua task close"
      linesOf fixture >>= (`shouldSatisfy` notElem "task closing after")

  describe "an epoch change" $ do
    it "settles a request whose completion is held as cancelled, releases its tick, and frees the place once the work is known over" $ bounded $ do
      fixture ← newIFixture
      fake ← newFake
      withBoundary $ \_ runtime → providersFinish fake $ do
        owner ← startRequester fixture runtime "epoch held" [asker] cmdConfig (logicalGrant fake 1 Nothing) requiredPolicy
        admitAsker fixture owner "i" "asker"
        command fixture owner "i" "start" "a"
        awaitLine fixture "cmd start a started"
        answerResult fake 0 7 >>= (`shouldBe` ReplyHeld)
        awaitLine fixture "disposed 0"
        awaitDiagnostic owner ((== 0) . rdWorkPending)
        void (advanceRequestEpoch (scheduledEndpoint owner))
        command fixture owner "i" "take" "a"
        awaitLine fixture "cmd take a {reason=epoch_change,status=cancelled}"
        awaitDiagnostic owner ((== 0) . rdOutstanding)
        d ← diagnostics owner
        (rdHeldNow d, rdEpochCancelled d) `shouldBe` (0, 1)
