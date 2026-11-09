-- | The opt-in settlement seam and the declining hand-off (TRA-5): a provider that commits a change at a request's settlement reads
-- the request's eligibility and settles it in its own transaction, so that a script's cancel and the commit are one arbitration; a
-- provider that cannot reserve its own banks inside the engine's admission declines the request and the admission is taken back whole.
module Test.LuaRuntime.Admission.Seam (spec) where

import Control.Concurrent.STM (atomically)
import Control.Exception (throwIO)
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Hetoimasia.Scripting.Lua.Provider
import Hetoimasia.Scripting.Lua.Value (Value (VInteger))
import Test.Hspec (Spec, describe, it, shouldBe)
import Test.LuaRuntime.Admission.Support
import Test.LuaRuntime.Request.Support (diagnostics, onSubmit, submissions)
import Test.LuaRuntime.Support (bounded, requiredPolicy, withBoundary)

-- | The seam of the request the provider was last handed.
captured ∷ IORef (Maybe Settling) → Submission → IO ()
captured ref submission = writeIORef ref (submissionSettling submission)

spec ∷ Spec
spec = describe "the settlement seam and the declining hand-off" $ do
  it "takes a request back whole when the provider declines it as busy, and a later call may succeed" $ bounded $ do
    fixture ← newAFix 4
    withBoundary $ \_ runtime → settleAll fixture $ do
      owner ← startAdmitting fixture runtime "declines" [admitter] aConfig (admissionGrant fixture 8 SettleOnArrival) requiredPolicy
      admitAdmitter fixture owner "i" "admitter"
      onSubmit (afFake fixture) (\_ → throwIO (DeclinedBusy "terrain arenas"))
      acommand fixture owner "i" "start" "a"
      awaitNote fixture "cmd start a busy:busy"
      -- Nothing is held, and nothing reached the provider as an accepted request.
      d ← diagnostics owner
      (rdOutstanding d, rdHeld d, rdBusy d, rdRefused d) `shouldBe` (0, 0, 0, 0)
      -- The provider has room again: the same call is accepted.
      onSubmit (afFake fixture) (\_ → pure ())
      acommand fixture owner "i" "start" "a"
      awaitNote fixture "cmd start a started"

  it "settles an eligible request in the provider's own transaction, and a cancel that came first leaves nothing eligible" $ bounded $ do
    fixture ← newAFix 4
    withBoundary $ \_ runtime → settleAll fixture $ do
      owner ← startAdmitting fixture runtime "seam" [admitter] aConfig (admissionGrant fixture 8 SettleOnArrival) requiredPolicy
      admitAdmitter fixture owner "i" "admitter"
      seam ← newIORef Nothing
      onSubmit (afFake fixture) (captured seam)
      acommand fixture owner "i" "start" "a"
      awaitNote fixture "cmd start a started"
      Just settling ← readIORef seam
      -- On elapsed time a request that is waiting is eligible, and settling it needs no position.
      atomically (settlingEligible settling) >>= (`shouldBe` True)
      atomically (settlingSettle settling (ProviderResult (VInteger 7))) >>= (`shouldBe` ReplySettled)
      atomically (settlingEligible settling) >>= (`shouldBe` False)
      acommand fixture owner "i" "take" "a"
      awaitNote fixture "cmd take a {status=success,value={v=7}}"
      -- A second request: the script's cancel wins first, so it is no longer eligible and the commit would not be made.
      onSubmit (afFake fixture) (captured seam)
      acommand fixture owner "i" "start" "b"
      awaitNote fixture "cmd start b started"
      Just second ← readIORef seam
      atomically (settlingEligible second) >>= (`shouldBe` True)
      acommand fixture owner "i" "cancel" "b"
      awaitNote fixture "cmd cancel b cancelled"
      atomically (settlingEligible second) >>= (`shouldBe` False)
      submissions (afFake fixture) >>= (`shouldBe` 2)
