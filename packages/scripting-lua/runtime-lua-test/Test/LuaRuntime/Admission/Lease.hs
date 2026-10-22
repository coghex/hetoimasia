-- | The result lease an opt-in request reserves (D-53, D-54): reserved with the request, built by the
-- owner into the instance's lease when the provider replies with a resource and only then
-- settled, live from then on whether or not the result is ever taken, released with the instance
-- (or when the request is cancelled before anyone could be handed it), and discharged unused when
-- no resource ever comes.
module Test.LuaRuntime.Admission.Lease (spec) where

import Control.Exception (ExceptionWithContext (ExceptionWithContext), throwIO)
import Hetoimasia.Foundation.Resource (acquirePart, releaseRank, restoredStep)
import Hetoimasia.Scripting.Lua.Admission
import Hetoimasia.Scripting.Lua.Instance
import Hetoimasia.Scripting.Lua.Lease (Ownership (..), ScopeSummary (..))
import Hetoimasia.Scripting.Lua.Provider
import Hetoimasia.Scripting.Lua.Runtime (LuaRuntime)
import Hetoimasia.Scripting.Lua.Scheduled
import Hetoimasia.Scripting.Lua.Value (Value (VInteger))
import Data.Text (Text)
import qualified Data.Text as Text
import Test.Hspec (Spec, describe, it, shouldBe, shouldSatisfy)
import Test.LuaRuntime.Admission.Support
import Test.LuaRuntime.Instance.Support (awaitSettled, expectControl, grantOne)
import Test.LuaRuntime.Request.Support (answerResult, answerWith, awaitCancelled, awaitDiagnostic, diagnostics, finishWork)
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

-- | Start a request of the @res@ endpoint, which reserves a result lease under the policy.
startRes ∷ AFix → ScheduledOwner → Text → Text → IO ()
startRes fixture owner name key = acommandWith fixture owner name "start" key (Just "res") (Just 1) Nothing

spec ∷ Spec
spec = describe "the result lease" $ do
  it "is built into the reserved lease by the owner when the provider replies with a resource, and settles only then" $ bounded $ do
    fixture ← newAFix 4
    setPolicy fixture (\held → held {polLease = Just InstanceOwned})
    withBoundary $ \_ runtime → settleAll fixture $ do
      owner ← arrival fixture runtime "adopts"
      admitAdmitter fixture owner "i" "admitter"
      startRes fixture owner "i" "a"
      awaitNote fixture "cmd start a started"
      leaseSummary fixture "i" >>= \summary → (summaryCharged summary, summaryLive summary, summaryConstructing summary) `shouldBe` (1, 0, 1)
      acommand fixture owner "i" "ready" "a"
      awaitNote fixture "cmd ready a false"
      -- The reply is accepted for adoption, not settled: nothing is visible to the script yet.
      answerResource fixture 0 5 "r1" >>= (`shouldBe` ReplyAdoption)
      awaitNote fixture "acquire r1"
      acommand fixture owner "i" "wait" "a"
      awaitNote fixture "cmd wait a woke"
      leaseSummary fixture "i" >>= \summary → (summaryCharged summary, summaryLive summary, summaryConstructing summary) `shouldBe` (1, 1, 0)
      d ← diagnostics owner
      (rdAdopted d, rdAdopting d) `shouldBe` (1, 0)

  it "stays live when the request is taken, and the request's place is given back while the lease is not" $ bounded $ do
    fixture ← newAFix 4
    bank ← newBank 2
    transferred ← newBank 2
    setPolicy fixture $ \held ->
      held
        { polLease = Just InstanceOwned
        , polCredits = [bankCredit "request" False bank, bankCredit "resource" True transferred]
        , polPerInstance = 1
        }
    withBoundary $ \_ runtime → settleAll fixture $ do
      owner ← arrival fixture runtime "taking"
      admitAdmitter fixture owner "i" "admitter"
      startRes fixture owner "i" "a"
      awaitNote fixture "cmd start a started"
      _ ← answerResource fixture 0 5 "r1"
      acommand fixture owner "i" "wait" "a"
      awaitNote fixture "cmd wait a woke"
      acommand fixture owner "i" "take_use" "a"
      line ← lineStarting fixture "cmd take_use a "
      (line `shouldSatisfy` Text.isSuffixOf " r1") >> (line `shouldSatisfy` Text.isInfixOf "status=success")
      -- The request's place and credit come back once the work is accounted; the resource's
      -- credit is the resource's, which the engine does not give back.
      awaitDiagnostic owner ((== 0) . rdHeld)
      bankLog bank >>= (`shouldBe` ["request CreditSettled"])
      bankLog transferred >>= (`shouldBe` [])
      bankAvailable transferred >>= (`shouldBe` 1)
      -- Taking did not release the lease: it is live, the same slot the request reserved.
      historyCount fixture "release r1" >>= (`shouldBe` 0)
      leaseSummary fixture "i" >>= \summary → (summaryCharged summary, summaryLive summary) `shouldBe` (1, 1)
      acommand fixture owner "i" "use" "a"
      awaitNote fixture "cmd use a r1"
      -- And the place is free for the next ask, which reserves another lease.
      startRes fixture owner "i" "b"
      awaitNote fixture "cmd start b started"

  it "releases a success nobody collected with the instance, on the owner's thread, without its script's help" $ bounded $ do
    fixture ← newAFix 4
    setPolicy fixture (\held → held {polLease = Just InstanceOwned})
    withBoundary $ \_ runtime → settleAll fixture $ do
      owner ← arrival fixture runtime "uncollected"
      admitAdmitter fixture owner "i" "admitter"
      startRes fixture owner "i" "a"
      awaitNote fixture "cmd start a started"
      _ ← answerResource fixture 0 5 "r1"
      awaitNote fixture "acquire r1"
      awaitLeaseSummary fixture "i" ((== 1) . summaryLive)
      historyCount fixture "release r1" >>= (`shouldBe` 0)
      _ ← expectControl (afBase fixture) owner "i" InstanceStop
      _ ← awaitSettled (afBase fixture) "i"
      awaitNote fixture "release r1"
      awaitLeaseSummary fixture "i" ((== 0) . summaryCharged)
      awaitDiagnostic owner ((== 0) . rdHeld)

  it "discharges the reservation unused when the provider fails the request, before anyone takes the failure" $ bounded $ do
    fixture ← newAFix 4
    setPolicy fixture (\held → held {polLease = Just InstanceOwned, polNecessity = OptionalRequest})
    withBoundary $ \_ runtime → settleAll fixture $ do
      owner ← arrival fixture runtime "failure"
      admitAdmitter fixture owner "i" "admitter"
      startRes fixture owner "i" "a"
      awaitNote fixture "cmd start a started"
      leaseSummary fixture "i" >>= (`shouldBe` 1) . summaryCharged
      answerExpected fixture 0 "io_error" >>= (`shouldBe` ReplySettled)
      awaitLeaseSummary fixture "i" ((== 0) . summaryCharged)
      -- The result is still there to take: the lease went, the request did not.
      heldBy fixture owner "i" >>= (`shouldBe` 1)
      historyCount fixture "acquire r1" >>= (`shouldBe` 0)

  it "discharges the reservation unused when the request is cancelled and its provider has retired" $ bounded $ do
    fixture ← newAFix 4
    setPolicy fixture (\held → held {polLease = Just InstanceOwned})
    withBoundary $ \_ runtime → settleAll fixture $ do
      owner ← arrival fixture runtime "cancelled"
      admitAdmitter fixture owner "i" "admitter"
      startRes fixture owner "i" "a"
      awaitNote fixture "cmd start a started"
      acommand fixture owner "i" "cancel" "a"
      awaitNote fixture "cmd cancel a cancelled"
      awaitCancelled (afFake fixture) 1
      -- Interest was withdrawn; the provider may still be using what it was given, so the
      -- reservation stays charged until it proves the work over.
      leaseSummary fixture "i" >>= (`shouldBe` 1) . summaryCharged
      finishWork (afFake fixture) 0
      awaitLeaseSummary fixture "i" ((== 0) . summaryCharged)

  it "discharges the reservation unused when the provider answers with no resource" $ bounded $ do
    fixture ← newAFix 4
    setPolicy fixture (\held → held {polLease = Just InstanceOwned})
    withBoundary $ \_ runtime → settleAll fixture $ do
      owner ← arrival fixture runtime "plain"
      admitAdmitter fixture owner "i" "admitter"
      startRes fixture owner "i" "a"
      awaitNote fixture "cmd start a started"
      answerResult (afFake fixture) 0 5 >>= (`shouldBe` ReplySettled)
      awaitLeaseSummary fixture "i" ((== 0) . summaryCharged)
      acommand fixture owner "i" "take" "a"
      awaitNote fixture "cmd take a {status=success,value={v=5}}"

  it "releases the resource of a request cancelled before its position, which nobody can be handed" $ bounded $ do
    fixture ← newAFix 4
    setPolicy fixture (\held → held {polLease = Just InstanceOwned})
    withBoundary $ \control runtime → settleAll fixture $ do
      owner ← logical fixture runtime "cancel after adoption"
      admitAdmitter fixture owner "i" "admitter"
      acommandWith fixture owner "i" "start" "a" (Just "res") (Just 1) (Just 2)
      awaitNote fixture "cmd start a started"
      answerResource fixture 0 5 "r1" >>= (`shouldBe` ReplyAdoption)
      awaitNote fixture "acquire r1"
      awaitLeaseSummary fixture "i" ((== 1) . summaryLive)
      -- Held for its position, still the instance's resource: cancelling wins, and releases it.
      acommand fixture owner "i" "cancel" "a"
      awaitNote fixture "cmd cancel a cancelled"
      awaitNote fixture "release r1"
      awaitLeaseSummary fixture "i" ((== 0) . summaryCharged)
      grantOne control owner
      grantOne control owner
      acommand fixture owner "i" "take" "a"
      awaitNote fixture "cmd take a {status=cancelled}"

  it "is a failure of the host when building the resource raises, the reservation given back and nothing published" $ bounded $ do
    fixture ← newAFix 4
    setPolicy fixture (\held → held {polLease = Just InstanceOwned})
    ExceptionWithContext _ failure ← expectFatal $ \control runtime → settleAll fixture $ do
      owner ← arrival fixture runtime "adoption fails"
      admitAdmitter fixture owner "i" "admitter"
      startRes fixture owner "i" "a"
      awaitNote fixture "cmd start a started"
      let breaking = Adoption $ \_ → do
            _ ← acquirePart "stage" (releaseRank 0) (() <$ note fixture "acquire stage") (\_ → note fixture "release stage")
            restoredStep (throwIO (Broken "adopt"))
            pure ("never" ∷ Text)
      _ ← answerWith (afFake fixture) 0 (ProviderResource (VInteger 5) breaking)
      awaitScheduledTerminal control owner
    failure `shouldSatisfy` brokenIs "adopt"
    -- The stage that completed was rolled back, and the reservation is given back.
    historyCount fixture "release stage" >>= (`shouldBe` 1)
    leaseSummary fixture "i" >>= (`shouldBe` 0) . summaryCharged
