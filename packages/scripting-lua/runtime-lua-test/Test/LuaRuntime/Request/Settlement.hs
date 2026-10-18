-- | Settlement: every admitted request settles exactly once, as a result, a failure or a
-- cancellation, on every path; a duplicate, late or stale reply never overwrites it, is counted,
-- and still retires the provider's work; a reply is bounded before it is retained; and the
-- interest in a request belongs to the instance that made it, or the task, and not to the
-- invocation.
module Test.LuaRuntime.Request.Settlement (spec) where

import qualified Data.Text as Text
import Hetoimasia.Scripting.Lua.Instance
import Hetoimasia.Scripting.Lua.Owner (BoundaryFault (boundaryReason), FaultReason (ScriptFailed))
import Hetoimasia.Scripting.Lua.Provider
import Hetoimasia.Scripting.Lua.Runtime (CallFault (BoundaryFailed))
import Hetoimasia.Scripting.Lua.Scheduled
import Hetoimasia.Scripting.Lua.Value
import Test.Hspec (Spec, describe, it, shouldBe, shouldSatisfy)
import Test.LuaRuntime.Instance.Support
import Test.LuaRuntime.Request.Support
import Test.LuaRuntime.Support (bounded, requiredPolicy, withBoundary)

-- | An owner of askers granted a provider with a path endpoint and a text endpoint.
textAndPath ∷ Fake → RequestGrant
textAndPath fake = RequestGrant [fakeEndpoint fake "path", fakeEndpointOf fake "text" SText] 4 SettleOnArrival

spec ∷ Spec
spec = describe "settlement" $ do
  describe "by the provider" $ do
    it "settles with the result or the failure the provider delivered, returned to the script as data" $ bounded $ do
      fixture ← newIFixture
      fake ← newFake
      withBoundary $ \_ runtime → providersFinish fake $ do
        owner ← startRequester fixture runtime "data" [asker] cmdConfig (grantOf fake 4) requiredPolicy
        admitAsker fixture owner "i" "asker"
        command fixture owner "i" "start" "a"
        awaitLine fixture "cmd start a started"
        command fixture owner "i" "start" "b"
        awaitLine fixture "cmd start b started"
        answerResult fake 0 7 >>= (`shouldBe` ReplySettled)
        answerWith fake 1 (ProviderFailure "no path") >>= (`shouldBe` ReplySettled)
        command fixture owner "i" "take" "a"
        awaitLine fixture "cmd take a {status=result,value=7}"
        command fixture owner "i" "take" "b"
        awaitLine fixture "cmd take b {reason=no path,status=failure}"

    it "keeps the first settlement against a duplicate reply, counts the duplicate, and still retires the work" $ bounded $ do
      fixture ← newIFixture
      fake ← newFake
      withBoundary $ \_ runtime → providersFinish fake $ do
        owner ← startRequester fixture runtime "duplicate" [asker] cmdConfig (grantOf fake 4) requiredPolicy
        admitAsker fixture owner "i" "asker"
        command fixture owner "i" "start" "a"
        awaitLine fixture "cmd start a started"
        answerResult fake 0 5 >>= (`shouldBe` ReplySettled)
        answerResult fake 0 6 >>= (`shouldBe` ReplyLate)
        command fixture owner "i" "take" "a"
        awaitLine fixture "cmd take a {status=result,value=5}"
        awaitDiagnostic owner ((== 0) . rdWorkPending)
        d ← diagnostics owner
        (rdLateReplies d, rdOutstanding d) `shouldBe` (1, 0)

    it "refuses a reply for a request already taken and reclaimed, as unknown, and counts it" $ bounded $ do
      fixture ← newIFixture
      fake ← newFake
      withBoundary $ \_ runtime → providersFinish fake $ do
        owner ← startRequester fixture runtime "stale" [asker] cmdConfig (grantOf fake 4) requiredPolicy
        admitAsker fixture owner "i" "asker"
        command fixture owner "i" "start" "a"
        awaitLine fixture "cmd start a started"
        answerResult fake 0 1 >>= (`shouldBe` ReplySettled)
        command fixture owner "i" "take" "a"
        awaitLine fixture "cmd take a {status=result,value=1}"
        answerResult fake 0 2 >>= (`shouldBe` ReplyUnknown)
        rdUnknownReplies <$> diagnostics owner >>= (`shouldBe` 1)

  describe "on an owner that settles on arrival" $ do
    it "keeps the settlement of a reply that came first against a later cancel, which is refused and counted" $ bounded $ do
      fixture ← newIFixture
      fake ← newFake
      withBoundary $ \_ runtime → providersFinish fake $ do
        owner ← startRequester fixture runtime "first wins" [asker] cmdConfig (grantOf fake 4) requiredPolicy
        admitAsker fixture owner "i" "asker"
        command fixture owner "i" "start" "a"
        awaitLine fixture "cmd start a started"
        answerResult fake 0 12 >>= (`shouldBe` ReplySettled)
        command fixture owner "i" "cancel" "a"
        awaitLine fixture "cmd cancel a settled"
        cancelledOrder fake >>= (`shouldBe` [])
        rdLateCancels <$> diagnostics owner >>= (`shouldBe` 1)
        command fixture owner "i" "take" "a"
        awaitLine fixture "cmd take a {status=result,value=12}"

    it "lets a cancel that came first win against a later reply, which is late and still retires the work" $ bounded $ do
      fixture ← newIFixture
      fake ← newFake
      withBoundary $ \_ runtime → providersFinish fake $ do
        owner ← startRequester fixture runtime "cancel first" [asker] cmdConfig (grantOf fake 4) requiredPolicy
        admitAsker fixture owner "i" "asker"
        command fixture owner "i" "start" "a"
        awaitLine fixture "cmd start a started"
        command fixture owner "i" "cancel" "a"
        awaitLine fixture "cmd cancel a cancelled"
        answerResult fake 0 12 >>= (`shouldBe` ReplyLate)
        command fixture owner "i" "take" "a"
        awaitLine fixture "cmd take a {reason=owner,status=cancelled}"
        awaitDiagnostic owner ((== 0) . rdWorkPending)

  describe "by the script's cancel" $ do
    it "settles as cancelled, tells the provider once, and lets a late reply retire the work without publishing" $ bounded $ do
      fixture ← newIFixture
      fake ← newFake
      withBoundary $ \_ runtime → providersFinish fake $ do
        owner ← startRequester fixture runtime "cancel" [asker] cmdConfig (grantOf fake 4) requiredPolicy
        admitAsker fixture owner "i" "asker"
        command fixture owner "i" "start" "a"
        awaitLine fixture "cmd start a started"
        command fixture owner "i" "cancel" "a"
        awaitLine fixture "cmd cancel a cancelled"
        cancelledOrder fake >>= (`shouldBe` [0])
        rdWorkPending <$> diagnostics owner >>= (`shouldBe` 1)
        -- The reply that comes after the cancel changes nothing the script sees, and it is
        -- the provider's proof that its work is over.
        answerResult fake 0 9 >>= (`shouldBe` ReplyLate)
        command fixture owner "i" "take" "a"
        awaitLine fixture "cmd take a {reason=owner,status=cancelled}"
        awaitDiagnostic owner ((== 0) . rdWorkPending)
        d ← diagnostics owner
        (rdLateReplies d, rdOutstanding d) `shouldBe` (1, 0)
        cancelledOrder fake >>= (`shouldBe` [0])

  describe "a reply is bounded before it is retained" $ do
    it "settles an unsettled request as a failure when the result is over the owner's limits, never retaining the value, and retires the work" $ bounded $ do
      fixture ← newIFixture
      fake ← newFake
      withBoundary $ \_ runtime → providersFinish fake $ do
        owner ← startRequesterWith fixture runtime (smallLimits (requestSpec fixture "oversize" [asker] cmdConfig (textAndPath fake) requiredPolicy))
        admitAsker fixture owner "i" "asker"
        commandFrom fixture owner "i" "start" "a" (Just "text") (Just 1)
        awaitLine fixture "cmd start a started"
        answerWith fake 0 (ProviderResult (VText (Text.replicate 2000 "x"))) >>= (`shouldBe` ReplyRefusedValue)
        -- The work is over, and what it needed is disposed of by the owner at its next boundary.
        awaitDiagnostic owner ((== 0) . rdWorkPending)
        rdOversize <$> diagnostics owner >>= (`shouldBe` 1)
        command fixture owner "i" "take" "a"
        awaitLine fixture "cmd take a {reason=the provider's result exceeded the payload cap,status=failure}"

    it "settles as a failure a result that is not what the endpoint declares" $ bounded $ do
      fixture ← newIFixture
      fake ← newFake
      withBoundary $ \_ runtime → providersFinish fake $ do
        owner ← startRequester fixture runtime "malformed" [asker] cmdConfig (grantOf fake 4) requiredPolicy
        admitAsker fixture owner "i" "asker"
        command fixture owner "i" "start" "a"
        awaitLine fixture "cmd start a started"
        answerWith fake 0 (ProviderResult (VText "not a number")) >>= (`shouldBe` ReplyRefusedValue)
        rdOversize <$> diagnostics owner >>= (`shouldBe` 0)
        command fixture owner "i" "take" "a"
        line ← awaitTaken fixture "cmd take a "
        line `shouldSatisfy` Text.isInfixOf "status=failure"
        line `shouldSatisfy` Text.isInfixOf "does not conform"

  describe "the interest in a request belongs to its instance" $ do
    it "is observed and taken in a later invocation when it was admitted in init" $ bounded $ do
      fixture ← newIFixture
      fake ← newFake
      withBoundary $ \_ runtime → providersFinish fake $ do
        owner ← startRequester fixture runtime "init" [initAsker] cmdConfig (grantOf fake 4) requiredPolicy
        admitAsker fixture owner "i" "initasker"
        awaitLine fixture "init started"
        answerResult fake 0 3 >>= (`shouldBe` ReplySettled)
        command fixture owner "i" "wait_take" "a"
        awaitLine fixture "cmd wait_take a {status=result,value=3}"

    it "is observed and taken in a later invocation when it was admitted in an update" $ bounded $ do
      fixture ← newIFixture
      fake ← newFake
      withBoundary $ \control runtime → providersFinish fake $ do
        owner ← startRequester fixture runtime "update" [updateAsker] cmdConfig (grantOf fake 4) requiredPolicy
        _ ← admitWith fixture owner "i" (InstanceRequest (moduleNamed "updateasker") (Periodic (LogicalTicks 1)) (Just "i") OrdinaryClass ["cmd", "tick"])
        awaitPhase fixture owner "i" Active
        grantOne control owner
        awaitLine fixture "update started u1"
        answerResult fake 0 4 >>= (`shouldBe` ReplySettled)
        command fixture owner "i" "take" "u1"
        awaitLine fixture "cmd take u1 {status=result,value=4}"

    it "cancels each when the instance stops, once, tells the providers, and settles only when they have proved their work over" $ bounded $ do
      fixture ← newIFixture
      fake ← newFake
      withBoundary $ \_ runtime → providersFinish fake $ do
        owner ← startRequester fixture runtime "stop" [asker] cmdConfig (grantOf fake 4) requiredPolicy
        admitAsker fixture owner "i" "asker"
        command fixture owner "i" "start" "a"
        awaitLine fixture "cmd start a started"
        command fixture owner "i" "start" "b"
        awaitLine fixture "cmd start b started"
        _ ← expectControl fixture owner "i" InstanceStop
        awaitCancelled fake 2
        cancelledOrder fake >>= (`shouldBe` [0, 1])
        d ← diagnostics owner
        (rdInvalidated d, rdDiscardedResults d) `shouldBe` (2, 2)
        -- Stopped as far as Lua is concerned; not as far as the providers are.
        awaitPhase fixture owner "i" Stopping
        tickOf fixture "i" >>= pollInstance >>= (`shouldSatisfy` \case Nothing → True; Just _ → False)
        finishWork fake 0
        finishWork fake 1
        settled ← awaitSettled fixture "i"
        resultOutcome settled `shouldSatisfy` \case InstanceStopped → True; _ → False
        awaitDiagnostic owner ((== 0) . rdOutstanding)
        cancelledOrder fake >>= (`shouldBe` [0, 1])

    it "cancels each when the instance fails, once" $ bounded $ do
      fixture ← newIFixture
      fake ← newFake
      withBoundary $ \_ runtime → providersFinish fake $ do
        owner ← startRequester fixture runtime "fail" [asker] cmdConfig (grantOf fake 4) requiredPolicy
        admitAsker fixture owner "i" "asker"
        command fixture owner "i" "start" "a"
        awaitLine fixture "cmd start a started"
        command fixture owner "i" "boom" "a"
        awaitCancelled fake 1
        finishWork fake 0
        settled ← awaitSettled fixture "i"
        case failureOf' settled of
          Just failure → case failureError failure of
            ErrorFault (BoundaryFailed fault) → boundaryReason fault `shouldSatisfy` \case ScriptFailed _ _ → True; _ → False
            other → fail ("expected a script fault, found " <> show other)
          Nothing → fail "expected the instance to fail"
        cancelledOrder fake >>= (`shouldBe` [0])
        rdInvalidated <$> diagnostics owner >>= (`shouldBe` 1)

  describe "the interest in a request belongs to a task that is no instance's" $ do
    it "is the task's to wait for and take, and its result reaches the task" $ bounded $ do
      fixture ← newIFixture
      fake ← newFake
      withBoundary $ \_ runtime → providersFinish fake $ do
        owner ← startRequester fixture runtime "task" [asker] cmdConfig (grantOf fake 4) requiredPolicy
        ticket ← taskOf owner "ask" [VText "path", VInteger 3]
        awaitSubmitted fake 1
        awaitLine fixture "task started 3"
        answerResult fake 0 30 >>= (`shouldBe` ReplySettled)
        _ ← waitTask ticket
        awaitLine fixture "task took 3 result 30"

    it "is revoked when the task ends, and the provider is told" $ bounded $ do
      fixture ← newIFixture
      fake ← newFake
      withBoundary $ \_ runtime → providersFinish fake $ do
        owner ← startRequester fixture runtime "task end" [asker] cmdConfig (grantOf fake 4) requiredPolicy
        ticket ← taskOf owner "start_only" [VText "path", VInteger 8]
        _ ← waitTask ticket
        awaitCancelled fake 1
        cancelledOrder fake >>= (`shouldBe` [0])
        rdInvalidated <$> diagnostics owner >>= (`shouldBe` 1)
        finishWork fake 0
        awaitDiagnostic owner ((== 0) . rdOutstanding)
