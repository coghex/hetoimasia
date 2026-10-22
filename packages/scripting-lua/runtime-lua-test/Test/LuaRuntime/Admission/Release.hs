-- | When the banks of an opt-in request come back: only when its result has been taken or
-- discarded and its provider's work has been accounted retired by the owner, exactly once, and
-- where the owner can see it: at once on its own thread when the retirement was accounted before the
-- take, and at its next boundary when a provider's thread completed the retirement.
module Test.LuaRuntime.Admission.Release (spec) where

import Control.Exception (ExceptionWithContext (ExceptionWithContext), toException)
import Hetoimasia.Scripting.Lua.Instance
import Hetoimasia.Scripting.Lua.Lease (Ownership (..))
import Hetoimasia.Scripting.Lua.Provider
import Hetoimasia.Scripting.Lua.Runtime (LuaRuntime)
import Hetoimasia.Scripting.Lua.Scheduled
import Control.Exception (throwIO)
import Test.Hspec (Spec, describe, it, shouldBe, shouldSatisfy)
import Test.LuaRuntime.Admission.Support
import Test.LuaRuntime.Instance.Support (awaitSettled, expectControl, sf)
import Test.LuaRuntime.Request.Support (answerResult, awaitCancelled, awaitDiagnostic, diagnostics, failWorkWith, finishWork, onSubmit, submissions)
import Test.LuaRuntime.Scheduled.Support (awaitEntered, awaitScheduledTerminal, releaseGate)
import Test.LuaRuntime.Support (Broken (Broken), bounded, brokenIs, expectFatal, requiredPolicy, withBoundary)
import Data.Text (Text)

-- | An owner of admitters on elapsed time.
arrival ∷ AFix → Int → LuaRuntime → Text → IO ScheduledOwner
arrival fixture bound runtime label =
  startAdmitting fixture runtime label [admitter] aConfig (admissionGrant fixture bound SettleOnArrival) requiredPolicy

spec ∷ Spec
spec = describe "release points" $ do
  describe "take before retirement" $ do
    it "holds the place after a cancellation is taken until the provider has proved its work over, then gives it back once" $ bounded $ do
      fixture ← newAFix 4
      bank ← newBank 3
      setPolicy fixture (\held → held {polPerInstance = 1, polCredits = [bankCredit "bytes" False bank]})
      withBoundary $ \_ runtime → settleAll fixture $ do
        owner ← arrival fixture 8 runtime "take first"
        admitAdmitter fixture owner "i" "admitter"
        acommand fixture owner "i" "start" "a"
        awaitNote fixture "cmd start a started"
        acommand fixture owner "i" "cancel" "a"
        awaitNote fixture "cmd cancel a cancelled"
        awaitCancelled (afFake fixture) 1
        acommand fixture owner "i" "take" "a"
        awaitNote fixture "cmd take a {status=cancelled}"
        -- Interest was withdrawn and the result taken: the provider has not proved it over, so
        -- the place and the credit are still held and nothing else can use them.
        acommand fixture owner "i" "start" "b"
        awaitNote fixture "cmd start b busy:busy"
        heldBy fixture owner "i" >>= (`shouldBe` 1)
        bankAvailable bank >>= (`shouldBe` 2)
        bankLog bank >>= (`shouldBe` [])
        finishWork (afFake fixture) 0
        awaitDiagnostic owner ((== 0) . rdHeld)
        bankAvailable bank >>= (`shouldBe` 3)
        -- Given back exactly once, with the reason it was.
        bankLog bank >>= (`shouldBe` ["bytes CreditSettled"])
        acommand fixture owner "i" "start" "b"
        awaitNote fixture "cmd start b started"

  describe "retirement before take" $ do
    it "frees the place on the owner's thread at the take that discards the result, so the next ask of the same call sees it" $ bounded $ do
      fixture ← newAFix 4
      setPolicy fixture (\held → held {polPerInstance = 1})
      withBoundary $ \_ runtime → settleAll fixture $ do
        owner ← arrival fixture 8 runtime "retire first"
        admitAdmitter fixture owner "i" "admitter"
        acommand fixture owner "i" "start" "a"
        awaitNote fixture "cmd start a started"
        acommand fixture owner "i" "cancel" "a"
        awaitNote fixture "cmd cancel a cancelled"
        awaitCancelled (afFake fixture) 1
        finishWork (afFake fixture) 0
        -- The provider's work is retired and accounted at the owner's boundary; the result is
        -- untaken, so the place is held.
        awaitDiagnostic owner ((== 0) . rdWorkPending)
        heldBy fixture owner "i" >>= (`shouldBe` 1)
        acommand fixture owner "i" "start" "b"
        awaitNote fixture "cmd start b busy:busy"
        -- Taking it now frees the place inside the same invocation: nothing is owed a boundary.
        acommand fixture owner "i" "start_take_start" "a"
        awaitNote fixture "cmd start_take_start a {status=cancelled} started"

  describe "a retirement a provider's thread completes" $ do
    it "is not visible to admission until the owner's next accounted boundary" $ bounded $ do
      fixture ← newAFix 4
      setPolicy fixture (\held → held {polPerInstance = 1})
      withBoundary $ \_ runtime → settleAll fixture $ do
        owner ← arrival fixture 8 runtime "boundary"
        admitAdmitter fixture owner "i" "admitter"
        acommand fixture owner "i" "start" "a"
        awaitNote fixture "cmd start a started"
        acommand fixture owner "i" "cancel" "a"
        awaitNote fixture "cmd cancel a cancelled"
        awaitCancelled (afFake fixture) 1
        acommand fixture owner "i" "take" "a"
        awaitNote fixture "cmd take a {status=cancelled}"
        -- The owner's thread is inside a script call, which holds it at a gate. The provider's
        -- thread proves its work over meanwhile: the place is not given back by that.
        acommand fixture owner "i" "block" "g"
        awaitEntered (sf (afBase fixture)) "g"
        finishWork (afFake fixture) 0
        d ← diagnostics owner
        (rdHeld d, rdWorkPending d) `shouldBe` (1, 1)
        releaseGate (sf (afBase fixture)) "g"
        awaitNote fixture "cmd block g unblocked"
        awaitDiagnostic owner ((== 0) . rdHeld)

  describe "losing a Lua reference" $ do
    it "does not give a place back: the handle is the instance's until its result is taken" $ bounded $ do
      fixture ← newAFix 4
      setPolicy fixture (\held → held {polPerInstance = 1})
      withBoundary $ \_ runtime → settleAll fixture $ do
        owner ← arrival fixture 8 runtime "lost"
        admitAdmitter fixture owner "i" "admitter"
        acommand fixture owner "i" "start" "a"
        awaitNote fixture "cmd start a started"
        acommand fixture owner "i" "drop" "a"
        awaitNote fixture "cmd drop a dropped"
        answerResult (afFake fixture) 0 4 >>= (`shouldBe` ReplySettled)
        awaitDiagnostic owner ((== 0) . rdWorkPending)
        heldBy fixture owner "i" >>= (`shouldBe` 1)
        acommand fixture owner "i" "start" "b"
        awaitNote fixture "cmd start b busy:busy"

  describe "an instance that ends" $ do
    it "has what it did not collect discarded, its places and credits given back once, without its script's help" $ bounded $ do
      fixture ← newAFix 4
      bank ← newBank 3
      setPolicy fixture (\held → held {polCredits = [bankCredit "bytes" False bank]})
      withBoundary $ \_ runtime → settleAll fixture $ do
        owner ← arrival fixture 8 runtime "ends"
        admitAdmitter fixture owner "i" "admitter"
        admitAdmitter fixture owner "j" "admitter"
        -- One at a time, so the provider's requests are numbered in this order.
        acommand fixture owner "i" "start" "a"
        awaitStarts fixture 1
        acommand fixture owner "i" "start" "b"
        awaitStarts fixture 2
        acommand fixture owner "j" "start" "a"
        awaitStarts fixture 3
        answerResult (afFake fixture) 0 1 >>= (`shouldBe` ReplySettled)
        awaitDiagnostic owner ((== 3) . rdHeld)
        _ ← expectControl (afBase fixture) owner "i" InstanceStop
        awaitCancelled (afFake fixture) 1
        finishWork (afFake fixture) 1
        awaitSettled' fixture "i"
        -- i's result was settled and never taken, and its other request was revoked: both are
        -- discarded, and j's request is untouched.
        awaitDiagnostic owner ((== 1) . rdHeld)
        heldBy fixture owner "j" >>= (`shouldBe` 1)
        bankLog bank >>= (`shouldBe` ["bytes CreditSettled", "bytes CreditSettled"])
        bankAvailable bank >>= (`shouldBe` 2)
        -- j still holds its own and can use it.
        acommand fixture owner "j" "ready" "a"
        awaitNote fixture "cmd ready a false"

  describe "a provider whose retirement failed" $ do
    it "keeps the place and the credit charged: nothing is reported as reclaimed" $ bounded $ do
      fixture ← newAFix 4
      bank ← newBank 1
      setPolicy fixture (\held → held {polCredits = [bankCredit "bytes" False bank]})
      ExceptionWithContext _ failure ← expectFatal $ \control runtime → settleAll fixture $ do
        owner ← arrival fixture 8 runtime "failed retirement"
        admitAdmitter fixture owner "i" "admitter"
        acommand fixture owner "i" "start" "a"
        awaitNote fixture "cmd start a started"
        acommand fixture owner "i" "cancel" "a"
        awaitNote fixture "cmd cancel a cancelled"
        awaitCancelled (afFake fixture) 1
        acommand fixture owner "i" "take" "a"
        awaitNote fixture "cmd take a {status=cancelled}"
        failWorkWith (afFake fixture) 0 (toException (Broken "retire"))
        status ← awaitScheduledTerminal control owner
        d ← diagnostics owner
        bankAvailable bank >>= (`shouldBe` 0)
        bankLog bank >>= (`shouldBe` [])
        (rdHeld d, rdWorkFailed d) `shouldBe` (1, 1)
        pure status
      failure `shouldSatisfy` brokenIs "retire"

  describe "an admission taken back" $ do
    it "returns the credits unused and discharges the reserved lease when the provider could not be handed the request" $ bounded $ do
      fixture ← newAFix 2
      bank ← newBank 2
      setPolicy fixture (\held → held {polLease = Just InstanceOwned, polCredits = [bankCredit "bytes" False bank]})
      onSubmit (afFake fixture) (\_ → throwIO (Broken "submit"))
      ExceptionWithContext _ failure ← expectFatal $ \control runtime → settleAll fixture $ do
        owner ← arrival fixture 8 runtime "taken back"
        admitAdmitter fixture owner "i" "admitter"
        acommand fixture owner "i" "start" "a"
        awaitScheduledTerminal control owner
      failure `shouldSatisfy` brokenIs "submit"
      bankAvailable bank >>= (`shouldBe` 2)
      bankLog bank >>= (`shouldBe` ["bytes CreditUnused"])
      submissions (afFake fixture) >>= (`shouldBe` 0)
  where
    awaitSettled' fixture name = awaitSettled (afBase fixture) name >>= \settlement → settlement `seq` pure ()
