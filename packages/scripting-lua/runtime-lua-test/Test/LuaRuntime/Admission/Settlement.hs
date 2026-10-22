-- | One settlement and the races around it: a provider that completes while it is being handed the
-- request, a request revoked while it is being handed over, duplicate, stale and late completions
-- that can never republish, and a disposal that fails.
module Test.LuaRuntime.Admission.Settlement (spec) where

import Control.Exception (ExceptionWithContext (ExceptionWithContext), throwIO)
import Control.Monad (void)
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.Text (Text)
import Hetoimasia.Scripting.Lua.Instance
import Hetoimasia.Scripting.Lua.Lease (Ownership (..), ScopeSummary (..))
import Hetoimasia.Scripting.Lua.Provider
import Hetoimasia.Scripting.Lua.Runtime (LuaRuntime)
import Hetoimasia.Scripting.Lua.Scheduled
import Hetoimasia.Scripting.Lua.Value (Value (VInteger))
import Test.Hspec (Spec, describe, it, shouldBe, shouldSatisfy)
import Test.LuaRuntime.Admission.Support
import Test.LuaRuntime.Instance.Support (expectControl, grantOne)
import Test.LuaRuntime.Request.Support (answerResult, awaitCancelled, awaitDiagnostic, diagnostics, finishWork, onSubmit, submissions)
import Test.LuaRuntime.Scheduled.Support (awaitScheduledTerminal)
import Test.LuaRuntime.Support (Broken (Broken), bounded, brokenIs, expectFatal, requiredPolicy, withBoundary)

-- | An owner of admitters on elapsed time.
arrival ∷ AFix → LuaRuntime → Text → IO ScheduledOwner
arrival fixture runtime label =
  startAdmitting fixture runtime label [admitter] aConfig (admissionGrant fixture 8 SettleOnArrival) requiredPolicy

-- | An owner of admitters on logical time.
logical ∷ AFix → LuaRuntime → Text → IO ScheduledOwner
logical fixture runtime label =
  startAdmitting fixture runtime label [admitter] aConfig (admissionGrant fixture 8 (SettleAtAssignedTick Nothing)) requiredPolicy

spec ∷ Spec
spec = describe "settlement" $ do
  describe "a provider that completes while it is being handed the request" $ do
    it "settles the request once, and the work it proved over by replying needs no retirement" $ bounded $ do
      fixture ← newAFix 4
      bank ← newBank 2
      setPolicy fixture (\held → held {polCredits = [bankCredit "bytes" False bank]})
      onSubmit (afFake fixture) (\submission → void (completeRequest (submissionCompletion submission) (ProviderResult (VInteger 4))))
      withBoundary $ \_ runtime → settleAll fixture $ do
        owner ← arrival fixture runtime "immediate"
        admitAdmitter fixture owner "i" "admitter"
        acommand fixture owner "i" "start" "a"
        awaitNote fixture "cmd start a started"
        acommand fixture owner "i" "take" "a"
        awaitNote fixture "cmd take a {status=success,value={v=4}}"
        awaitDiagnostic owner ((== 0) . rdHeld)
        bankLog bank >>= (`shouldBe` ["bytes CreditSettled"])
        d ← diagnostics owner
        (rdSettledAtTick d, rdLateReplies d) `shouldBe` (0, 0)

    it "has the resource of an immediate resource reply built into the lease once the request is accepted" $ bounded $ do
      fixture ← newAFix 4
      setPolicy fixture (\held → held {polLease = Just InstanceOwned})
      onSubmit (afFake fixture) $ \submission →
        void (completeRequest (submissionCompletion submission) (ProviderResource (VInteger 4) (Adoption (\_ → resourceFor fixture "r1"))))
      withBoundary $ \_ runtime → settleAll fixture $ do
        owner ← arrival fixture runtime "immediate resource"
        admitAdmitter fixture owner "i" "admitter"
        acommandWith fixture owner "i" "start" "a" (Just "res") (Just 1) Nothing
        awaitNote fixture "cmd start a started"
        awaitNote fixture "acquire r1"
        awaitLeaseSummary fixture "i" ((== 1) . summaryLive)
        acommand fixture owner "i" "wait_take" "a"
        line ← lineStarting fixture "cmd wait_take a "
        line `shouldSatisfy` (/= "")

  describe "a request revoked while it is being handed over" $ do
    it "is cancelled by the epoch, its provider told once it has it, and everything it reserved given back at the right end" $ bounded $ do
      fixture ← newAFix 4
      bank ← newBank 2
      endpoint ← newIORef Nothing
      setPolicy fixture (\held → held {polLease = Just InstanceOwned, polCredits = [bankCredit "bytes" False bank]})
      onSubmit (afFake fixture) $ \_ →
        readIORef endpoint >>= maybe (pure ()) (void . advanceRequestEpoch)
      withBoundary $ \_ runtime → settleAll fixture $ do
        owner ← arrival fixture runtime "revoked"
        writeIORef endpoint (Just (scheduledEndpoint owner))
        admitAdmitter fixture owner "i" "admitter"
        acommandWith fixture owner "i" "start" "a" (Just "res") (Just 1) Nothing
        awaitNote fixture "cmd start a started"
        -- The provider is told as soon as the engine has it, though it was revoked first.
        awaitCancelled (afFake fixture) 1
        acommand fixture owner "i" "take" "a"
        awaitNote fixture "cmd take a {status=cancelled}"
        -- The provider's work is still running: nothing is given back.
        bankLog bank >>= (`shouldBe` [])
        leaseSummary fixture "i" >>= (`shouldBe` 1) . summaryCharged
        finishWork (afFake fixture) 0
        awaitDiagnostic owner ((== 0) . rdHeld)
        bankLog bank >>= (`shouldBe` ["bytes CreditSettled"])
        awaitLeaseSummary fixture "i" ((== 0) . summaryCharged)

  describe "a completion that cannot republish" $ do
    it "is late after the request was cancelled and taken, then unknown once the work is accounted over, and changes nothing" $ bounded $ do
      fixture ← newAFix 4
      withBoundary $ \_ runtime → settleAll fixture $ do
        owner ← arrival fixture runtime "late"
        admitAdmitter fixture owner "i" "admitter"
        acommand fixture owner "i" "start" "a"
        awaitNote fixture "cmd start a started"
        acommand fixture owner "i" "cancel" "a"
        awaitNote fixture "cmd cancel a cancelled"
        awaitCancelled (afFake fixture) 1
        acommand fixture owner "i" "take" "a"
        awaitNote fixture "cmd take a {status=cancelled}"
        answerResult (afFake fixture) 0 5 >>= (`shouldBe` ReplyLate)
        awaitDiagnostic owner ((== 0) . rdHeld)
        answerResult (afFake fixture) 0 6 >>= (`shouldBe` ReplyUnknown)
        d ← diagnostics owner
        (rdLateReplies d, rdUnknownReplies d, rdHeldNow d) `shouldBe` (1, 1, 0)

    it "is a duplicate when the first is still held for its tick: counted, never replacing it" $ bounded $ do
      fixture ← newAFix 4
      withBoundary $ \control runtime → settleAll fixture $ do
        owner ← logical fixture runtime "duplicate"
        admitAdmitter fixture owner "i" "admitter"
        acommand fixture owner "i" "start" "a"
        awaitNote fixture "cmd start a started"
        answerResult (afFake fixture) 0 1 >>= (`shouldBe` ReplyHeld)
        answerResult (afFake fixture) 0 2 >>= (`shouldBe` ReplyLate)
        grantOne control owner
        acommand fixture owner "i" "take" "a"
        awaitNote fixture "cmd take a {status=success,value={v=1}}"
        d ← diagnostics owner
        rdDuplicateHeld d `shouldBe` 1

    it "is never a second settlement of a request an ended instance had: it finds nothing to settle" $ bounded $ do
      fixture ← newAFix 4
      withBoundary $ \_ runtime → settleAll fixture $ do
        owner ← arrival fixture runtime "ended"
        admitAdmitter fixture owner "i" "admitter"
        acommand fixture owner "i" "start" "a"
        awaitNote fixture "cmd start a started"
        _ ← expectControl (afBase fixture) owner "i" InstanceStop
        awaitCancelled (afFake fixture) 1
        answerResult (afFake fixture) 0 9 >>= (`shouldBe` ReplyLate)
        submissions (afFake fixture) >>= (`shouldBe` 1)

  describe "a disposal that fails" $ do
    it "is a cleanup failure, fatal, and the place stays charged: nothing is reported as reclaimed" $ bounded $ do
      fixture ← newAFix 4
      bank ← newBank 1
      setPolicy fixture (\held → held {polDisposal = Just (throwIO (Broken "dispose")), polCredits = [bankCredit "bytes" False bank]})
      ExceptionWithContext _ failure ← expectFatal $ \control runtime → settleAll fixture $ do
        owner ← arrival fixture runtime "disposal"
        admitAdmitter fixture owner "i" "admitter"
        acommand fixture owner "i" "start" "a"
        awaitNote fixture "cmd start a started"
        _ ← answerResult (afFake fixture) 0 1
        status ← awaitScheduledTerminal control owner
        bankLog bank >>= (`shouldBe` [])
        pure status
      failure `shouldSatisfy` brokenIs "dispose"
