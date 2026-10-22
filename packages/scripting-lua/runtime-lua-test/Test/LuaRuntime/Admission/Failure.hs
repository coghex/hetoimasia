-- | What a failure of an opt-in request does (D-52): a required request's expected failure fails its
-- instance at the owner's next safe boundary whether or not the script ever reads it, and nothing the
-- script does afterwards clears that; an optional one is a result to read; a cancellation that wins
-- prevents it; and an engine, provider or cleanup defect is fatal for both, never data.
module Test.LuaRuntime.Admission.Failure (spec) where

import Control.Exception (ExceptionWithContext (ExceptionWithContext), fromException, throwIO, toException)
import Control.Monad (forM_)
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.Text (Text)
import qualified Data.Text as Text
import Hetoimasia.Scripting.Lua.Admission
import Hetoimasia.Scripting.Lua.Instance
import Hetoimasia.Scripting.Lua.Provider
import Hetoimasia.Scripting.Lua.Runtime (LuaRuntime)
import Hetoimasia.Scripting.Lua.Scheduled
import Hetoimasia.Scripting.Lua.Value (Value (VText))
import Test.Hspec (Spec, describe, it, shouldBe, shouldSatisfy)
import Test.LuaRuntime.Admission.Support
import Test.LuaRuntime.Instance.Support (awaitPhase, awaitSettled, failureOf', grantOne, sf)
import Test.LuaRuntime.Request.Support (answerWith, awaitCancelled, diagnostics, failWorkWith, onSubmit)
import Test.LuaRuntime.Scheduled.Support (awaitEntered, awaitScheduledTerminal, releaseGate)
import Test.LuaRuntime.Support (Broken (Broken), bounded, brokenIs, expectFatal, requiredPolicy, withBoundary)

-- | An owner of admitters on elapsed time.
arrival ∷ AFix → LuaRuntime → Text → IO ScheduledOwner
arrival fixture runtime label =
  startAdmitting fixture runtime label [admitter] aConfig (admissionGrant fixture 8 SettleOnArrival) requiredPolicy

-- | An owner of admitters on logical time.
logical ∷ AFix → LuaRuntime → Text → IO ScheduledOwner
logical fixture runtime label =
  startAdmitting fixture runtime label [admitter] aConfig (admissionGrant fixture 8 (SettleAtAssignedTick Nothing)) requiredPolicy

-- | The endpoint and the attributed text an instance failed with, if it failed with a required
-- request's.
requestFailure ∷ InstanceSettlement → Maybe (Text, Text)
requestFailure settlement = do
  failure ← failureOf' settlement
  case failureError failure of
    ErrorRequest endpoint why → Just (endpoint, why)
    _ → Nothing

-- | The same, from the failure the application was told.
requestFailure' ∷ InstanceFailure → Maybe (Text, Text)
requestFailure' failure = case failureError failure of
  ErrorRequest endpoint why → Just (endpoint, why)
  _ → Nothing

spec ∷ Spec
spec = describe "failure" $ do
  describe "a required request's expected failure" $ do
    it "fails its instance at the next safe boundary whether or not its script ever reads the request, attributed to the request" $ bounded $ do
      fixture ← newAFix 4
      setPolicy fixture (\held → held {polSource = "the title screen"})
      withBoundary $ \_ runtime → settleAll fixture $ do
        owner ← arrival fixture runtime "required"
        admitAdmitter fixture owner "i" "admitter"
        acommand fixture owner "i" "start" "a"
        awaitNote fixture "cmd start a started"
        answerExpected fixture 0 "not_found" >>= (`shouldBe` ReplySettled)
        settlement ← awaitSettled (afBase fixture) "i"
        requestFailure settlement `shouldBe` Just ("path", "(the title screen) not_found: detail of not_found")
        fmap failureStage (failureOf' settlement) `shouldBe` Just (StageRequest "path")
        d ← diagnostics owner
        rdLatched d `shouldBe` 1

    it "reaches the application through the existing escalation boundary, once, as the instance's failure" $ bounded $ do
      fixture ← newAFix 4
      told ← newIORef []
      let config = aConfig {instanceEscalate = \failure → modifyIORef' told (failure :) >> pure Isolate}
      withBoundary $ \_ runtime → settleAll fixture $ do
        owner ← startAdmitting fixture runtime "escalation" [admitter] config (admissionGrant fixture 8 SettleOnArrival) requiredPolicy
        admitAdmitter fixture owner "i" "admitter"
        acommand fixture owner "i" "start" "a"
        awaitNote fixture "cmd start a started"
        _ ← answerExpected fixture 0 "not_found"
        settlement ← awaitSettled (afBase fixture) "i"
        fmap fst (requestFailure settlement) `shouldBe` Just "path"
        seen ← readIORef told
        map (fmap fst . requestFailure' ) seen `shouldBe` [Just "path"]

    it "is unseen until its position on logical time, and fails the instance when the position is reached" $ bounded $ do
      fixture ← newAFix 4
      withBoundary $ \control runtime → settleAll fixture $ do
        owner ← logical fixture runtime "required logical"
        admitAdmitter fixture owner "i" "admitter"
        acommand fixture owner "i" "start" "a"
        awaitNote fixture "cmd start a started"
        answerExpected fixture 0 "io_error" >>= (`shouldBe` ReplyHeld)
        -- Early, it is held and nothing of it reaches the script or the instance.
        acommand fixture owner "i" "ready" "a"
        awaitNote fixture "cmd ready a false"
        d ← diagnostics owner
        (rdLatched d, rdHeldNow d) `shouldBe` (0, 1)
        awaitPhase (afBase fixture) owner "i" Active
        grantOne control owner
        settlement ← awaitSettled (afBase fixture) "i"
        fmap fst (requestFailure settlement) `shouldBe` Just "path"

    it "fails the instance before the script that waits for the request is resumed: no ordinary work follows the eligible failure" $ bounded $ do
      fixture ← newAFix 4
      withBoundary $ \control runtime → settleAll fixture $ do
        owner ← logical fixture runtime "waiter"
        admitAdmitter fixture owner "i" "admitter"
        acommand fixture owner "i" "start" "a"
        awaitNote fixture "cmd start a started"
        acommand fixture owner "i" "wait" "a"
        awaitNote fixture "waiting a"
        answerExpected fixture 0 "not_found" >>= (`shouldBe` ReplyHeld)
        grantOne control owner
        settlement ← awaitSettled (afBase fixture) "i"
        fmap fst (requestFailure settlement) `shouldBe` Just "path"
        seen ← history fixture
        seen `shouldSatisfy` notElem "cmd wait a woke"

    it "is not cleared by an error the script caught or by a cancel it made afterwards: the failure was already latched" $ bounded $ do
      fixture ← newAFix 4
      withBoundary $ \_ runtime → settleAll fixture $ do
        owner ← arrival fixture runtime "late cancel"
        admitAdmitter fixture owner "i" "admitter"
        acommand fixture owner "i" "start" "a"
        awaitNote fixture "cmd start a started"
        -- The script is held inside a call while the provider answers, then goes on: it cancels
        -- the settled request, and catches two errors of its own.
        acommand fixture owner "i" "late" "a"
        awaitEntered (sf (afBase fixture)) "a"
        answerExpected fixture 0 "not_found" >>= (`shouldBe` ReplySettled)
        releaseGate (sf (afBase fixture)) "a"
        awaitNote fixture "cmd late a already_settled false false"
        settlement ← awaitSettled (afBase fixture) "i"
        fmap fst (requestFailure settlement) `shouldBe` Just "path"

    it "is prevented by a cancel that won, and a reply that comes after it is late and latches nothing" $ bounded $ do
      fixture ← newAFix 4
      withBoundary $ \_ runtime → settleAll fixture $ do
        owner ← arrival fixture runtime "cancel first"
        admitAdmitter fixture owner "i" "admitter"
        acommand fixture owner "i" "start" "a"
        awaitNote fixture "cmd start a started"
        acommand fixture owner "i" "cancel" "a"
        awaitNote fixture "cmd cancel a cancelled"
        awaitCancelled (afFake fixture) 1
        answerExpected fixture 0 "not_found" >>= (`shouldBe` ReplyLate)
        acommand fixture owner "i" "take" "a"
        awaitNote fixture "cmd take a {status=cancelled}"
        d ← diagnostics owner
        rdLatched d `shouldBe` 0
        awaitPhase (afBase fixture) owner "i" Active

  describe "an optional request's expected failure" $ do
    it "is a result for the script, whole, and fails nobody" $ bounded $ do
      fixture ← newAFix 4
      setPolicy fixture (\held → held {polNecessity = OptionalRequest})
      withBoundary $ \_ runtime → settleAll fixture $ do
        owner ← arrival fixture runtime "optional"
        admitAdmitter fixture owner "i" "admitter"
        acommand fixture owner "i" "start" "a"
        awaitNote fixture "cmd start a started"
        answerExpected fixture 0 "not_found" >>= (`shouldBe` ReplySettled)
        acommand fixture owner "i" "take" "a"
        awaitNote fixture "cmd take a {error={code=not_found,message=detail of not_found,path=path/to/file,root=root},status=failure}"
        d ← diagnostics owner
        rdLatched d `shouldBe` 0
        awaitPhase (afBase fixture) owner "i" Active

    it "carries a message that is cut at a character, visibly, to the bound" $ bounded $ do
      fixture ← newAFix 4
      setPolicy fixture (\held → held {polNecessity = OptionalRequest})
      withBoundary $ \_ runtime → settleAll fixture $ do
        owner ← arrival fixture runtime "cut"
        admitAdmitter fixture owner "i" "admitter"
        acommand fixture owner "i" "start" "a"
        awaitNote fixture "cmd start a started"
        -- Two bytes each: the 2 KiB bound keeps 1,022 whole characters and a three byte mark.
        _ ← answerWith (afFake fixture) 0 (ProviderExpected (ExpectedFailure "io_error" (Text.replicate 5000 "é") Nothing Nothing))
        acommand fixture owner "i" "take" "a"
        awaitNote fixture ("cmd take a {error={code=io_error,message=" <> Text.replicate 1022 "é" <> "...},status=failure}")

  describe "a provider's defect" $ do
    forM_ defects $ \(label, reply) →
      it ("is fatal, never a failure of the request or data, even for an optional one: " <> label) $ bounded $ do
        fixture ← newAFix 4
        setPolicy fixture (\held → held {polNecessity = OptionalRequest})
        ExceptionWithContext _ failure ← expectFatal $ \control runtime → settleAll fixture $ do
          owner ← arrival fixture runtime "defect"
          admitAdmitter fixture owner "i" "admitter"
          acommand fixture owner "i" "start" "a"
          awaitNote fixture "cmd start a started"
          answerWith (afFake fixture) 0 reply >>= (`shouldBe` ReplyDefective)
          awaitScheduledTerminal control owner
        (fromException failure ∷ Maybe ProviderDefect) `shouldSatisfy` \case
          Just (ProviderDefect why) → not (Text.null why) && Text.length why <= 512
          Nothing → False

    it "is not an expected failure when a provider raises when handed the request: the failure keeps its own type" $ bounded $ do
      fixture ← newAFix 4
      setPolicy fixture (\held → held {polNecessity = OptionalRequest})
      onSubmit (afFake fixture) (\_ → throwIO (Broken "submit"))
      ExceptionWithContext _ failure ← expectFatal $ \control runtime → settleAll fixture $ do
        owner ← arrival fixture runtime "submit"
        admitAdmitter fixture owner "i" "admitter"
        acommand fixture owner "i" "start" "a"
        awaitScheduledTerminal control owner
      failure `shouldSatisfy` brokenIs "submit"

    it "is a cleanup failure when a provider's retirement fails, fatal for an optional request too" $ bounded $ do
      fixture ← newAFix 4
      setPolicy fixture (\held → held {polNecessity = OptionalRequest})
      ExceptionWithContext _ failure ← expectFatal $ \control runtime → settleAll fixture $ do
        owner ← arrival fixture runtime "retire"
        admitAdmitter fixture owner "i" "admitter"
        acommand fixture owner "i" "start" "a"
        awaitNote fixture "cmd start a started"
        acommand fixture owner "i" "cancel" "a"
        awaitNote fixture "cmd cancel a cancelled"
        awaitCancelled (afFake fixture) 1
        failWorkWith (afFake fixture) 0 (toException (Broken "retire"))
        awaitScheduledTerminal control owner
      failure `shouldSatisfy` brokenIs "retire"
  where
    defects ∷ [(String, ProviderReply)]
    defects =
      [ ("a result that is not what the endpoint declares", ProviderResult (VText "not an integer"))
      , ("a failure with no code its service supplies", ProviderFailure "no code")
      , ("a failure whose code its service does not supply", ProviderExpected (ExpectedFailure "unheard_of" "message" Nothing Nothing))
      , ("a failure whose path is over its bound", ProviderExpected (ExpectedFailure "not_found" "message" Nothing (Just (Text.replicate 1025 "p"))))
      ]
