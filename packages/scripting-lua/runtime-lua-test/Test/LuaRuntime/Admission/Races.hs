-- | The races of the opt-in admission that a review of the first delivery found: a withdrawal
-- whose credit release raises, a second reply while a resource waits to be built, credits that
-- transfer to a resource built after its request was cancelled, a required failure latched when the
-- instance ends before it is applied, and a failure whose fields throw when looked at.
module Test.LuaRuntime.Admission.Races (spec) where

import Control.Concurrent (forkIO)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, readMVar, takeMVar, tryPutMVar)
import Control.Concurrent.STM (atomically, modifyTVar', throwSTM)
import Control.Exception (ExceptionWithContext (ExceptionWithContext), fromException, throwIO)
import Control.Monad (forM, void)
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.Text (Text)
import qualified Data.Text as Text
import Hetoimasia.Foundation.Resource (acquirePart, cleanupFailureLabel, cleanupFailuresInContext, releaseRank)
import Hetoimasia.Scripting.Lua.Admission
import Hetoimasia.Scripting.Lua.Instance
import Hetoimasia.Scripting.Lua.Lease (Ownership (..), ScopeSummary (..))
import Hetoimasia.Scripting.Lua.Provider
import Hetoimasia.Scripting.Lua.Runtime (LuaRuntime)
import Hetoimasia.Scripting.Lua.Scheduled
import Hetoimasia.Scripting.Lua.Value (Value (VInteger))
import Test.Hspec (Spec, describe, it, shouldBe, shouldSatisfy)
import Test.LuaRuntime.Admission.Support
import Test.LuaRuntime.Instance.Support (admitWith, awaitSettled, expectControl, failureOf', moduleNamed, sf)
import Test.LuaRuntime.Request.Support (answerResult, answerWith, awaitDiagnostic, diagnostics, finishWork, onCancel, onSubmit)
import Test.LuaRuntime.Scheduled.Support (awaitEntered, awaitScheduledTerminal, releaseGate)
import Test.LuaRuntime.Support (Broken (Broken), bounded, brokenIs, expectFatal, requiredPolicy, tryExpected, withBoundary)

-- | An owner of admitters on elapsed time.
arrival ∷ AFix → LuaRuntime → Text → IO ScheduledOwner
arrival fixture runtime label =
  startAdmitting fixture runtime label [admitter, oneShotStarter] aConfig (admissionGrant fixture 8 SettleOnArrival) requiredPolicy

spec ∷ Spec
spec = describe "races" $ do
  describe "a withdrawal whose credit release raises" $ do
    it "still takes the unsubmitted work back, keeps both failures, and lets the owner end" $ bounded $ do
      fixture ← newAFix 4
      bank ← newBank 2
      let breaking = (bankCredit "bytes" False bank) {creditRelease = \_ → throwSTM (Broken "release")}
      setPolicy fixture (\held → held {polCredits = [breaking, bankCredit "other" False bank]})
      onSubmit (afFake fixture) (\_ → throwIO (Broken "submit"))
      ExceptionWithContext context failure ← expectFatal $ \control runtime → settleAll fixture $ do
        owner ← arrival fixture runtime "withdrawal"
        admitAdmitter fixture owner "i" "admitter"
        acommand fixture owner "i" "start" "a"
        awaitScheduledTerminal control owner
      failure `shouldSatisfy` brokenIs "submit"
      let evidence = [(cleanupFailureLabel found, ()) | found ← cleanupFailuresInContext context]
      map fst evidence `shouldSatisfy` elem "lua credit release"
      -- The independent credit was returned; nothing waits for work that has no provider.
      bankLog bank >>= (`shouldBe` ["other CreditUnused"])

    it "keeps a release that raises at the end of a request as cleanup evidence, fatal, and returns the others" $ bounded $ do
      fixture ← newAFix 4
      bank ← newBank 2
      let breaking = (bankCredit "bytes" False bank) {creditRelease = \_ → throwSTM (Broken "release")}
      setPolicy fixture (\held → held {polCredits = [breaking, bankCredit "other" False bank]})
      ExceptionWithContext context _ ← expectFatal $ \control runtime → settleAll fixture $ do
        owner ← arrival fixture runtime "settled release"
        admitAdmitter fixture owner "i" "admitter"
        acommand fixture owner "i" "start" "a"
        awaitNote fixture "cmd start a started"
        _ ← answerResult (afFake fixture) 0 1
        acommand fixture owner "i" "take" "a"
        awaitNote fixture "cmd take a {status=success,value={v=1}}"
        awaitScheduledTerminal control owner
      map cleanupFailureLabel (cleanupFailuresInContext context) `shouldSatisfy` elem "lua credit release"
      bankLog bank >>= (`shouldBe` ["other CreditSettled"])

    it "keeps a release that raises when the owner is exiting, where nothing but the retirement services the provider" $ bounded $ do
      fixture ← newAFix 4
      bank ← newBank 1
      let breaking = (bankCredit "bytes" False bank) {creditRelease = \_ → throwSTM (Broken "release")}
      setPolicy fixture (\held → held {polCredits = [breaking]})
      ExceptionWithContext context _ ← expectFatal $ \control runtime → settleAll fixture $ do
        owner ← arrival fixture runtime "exiting"
        admitAdmitter fixture owner "i" "admitter"
        acommand fixture owner "i" "start" "a"
        awaitNote fixture "cmd start a started"
        -- The provider proves its work over only when the exit tells it interest was withdrawn.
        onCancel (afFake fixture) (finishWork (afFake fixture))
        retireScheduled owner
        awaitScheduledTerminal control owner
      map cleanupFailureLabel (cleanupFailuresInContext context) `shouldSatisfy` elem "lua credit release"

  describe "a second reply while a resource waits to be built" $ do
    it "is a duplicate whatever it is, and replaces nothing" $ bounded $ do
      fixture ← newAFix 4
      setPolicy fixture (\held → held {polLease = Just InstanceOwned})
      withBoundary $ \_ runtime → settleAll fixture $ do
        owner ← arrival fixture runtime "mixed"
        admitAdmitter fixture owner "i" "admitter"
        acommandWith fixture owner "i" "start" "a" (Just "res") (Just 1) Nothing
        awaitNote fixture "cmd start a started"
        -- The owner is held inside a call, so the resource cannot be built yet.
        acommand fixture owner "i" "block" "g"
        awaitEntered (sf (afBase fixture)) "g"
        answerResource fixture 0 5 "r1" >>= (`shouldBe` ReplyAdoption)
        answerResult (afFake fixture) 0 6 >>= (`shouldBe` ReplyLate)
        answerExpected fixture 0 "not_found" >>= (`shouldBe` ReplyLate)
        answerResource fixture 0 7 "r2" >>= (`shouldBe` ReplyLate)
        releaseGate (sf (afBase fixture)) "g"
        awaitNote fixture "acquire r1"
        acommand fixture owner "i" "wait_take" "a"
        line ← lineStarting fixture "cmd wait_take a "
        line `shouldSatisfy` (\found → found /= "")
        d ← diagnostics owner
        (rdLatched d, rdAdopted d) `shouldBe` (0, 1)
        historyCount fixture "acquire r2" >>= (`shouldBe` 0)

  describe "credits that transfer to a resource built after its request was cancelled" $ do
    it "belong to the resource, which returns them once, and the request does not return them again" $ bounded $ do
      fixture ← newAFix 4
      bank ← newBank 1
      endpoint ← newIORef Nothing
      entered ← newEmptyMVar
      proceed ← newEmptyMVar
      setPolicy fixture (\held → held {polLease = Just InstanceOwned, polCredits = [bankCredit "pixels" True bank]})
      let building =
            Adoption $ \_ → do
              _ ←
                acquirePart
                  "texture"
                  (releaseRank 0)
                  (void (tryPutMVar entered ()) >> readMVar proceed)
                  -- The resource's own release returns what it was charged.
                  (\_ → atomically (modifyTVar' (bkLeft bank) (+ 1)) >> note fixture "release texture")
              pure ("texture" ∷ Text)
      withBoundary $ \_ runtime → settleAll fixture $ do
        owner ← arrival fixture runtime "transfer"
        writeIORef endpoint (Just (scheduledEndpoint owner))
        admitAdmitter fixture owner "i" "admitter"
        acommandWith fixture owner "i" "start" "a" (Just "res") (Just 1) Nothing
        awaitNote fixture "cmd start a started"
        bankAvailable bank >>= (`shouldBe` 0)
        answerWith (afFake fixture) 0 (ProviderResource (VInteger 5) building) >>= (`shouldBe` ReplyAdoption)
        -- The owner is inside the builder: the epoch cancels the request now.
        readMVar entered
        readIORef endpoint >>= maybe (pure ()) (void . advanceRequestEpoch)
        putMVar proceed ()
        awaitNote fixture "release texture"
        acommand fixture owner "i" "take" "a"
        awaitNote fixture "cmd take a {status=cancelled}"
        awaitDiagnostic owner ((== 0) . rdHeld)
        -- Returned by the resource once, and not again by the request.
        bankAvailable bank >>= (`shouldBe` 1)
        bankLog bank >>= (`shouldBe` [])

  describe "a resource adopted for a result nobody took when the epoch changes" $ do
    it "is released with the epoch: the lease and the credits that transferred are not held until the instance ends" $ bounded $ do
      fixture ← newAFix 4
      bank ← newBank 1
      setPolicy fixture (\held → held {polLease = Just InstanceOwned, polCredits = [bankCredit "pixels" True bank]})
      withBoundary $ \_ runtime → settleAll fixture $ do
        owner ← arrival fixture runtime "epoch after adoption"
        admitAdmitter fixture owner "i" "admitter"
        acommandWith fixture owner "i" "start" "a" (Just "res") (Just 1) Nothing
        awaitNote fixture "cmd start a started"
        answerResource fixture 0 5 "r1" >>= (`shouldBe` ReplyAdoption)
        awaitNote fixture "acquire r1"
        awaitLeaseSummary fixture "i" ((== 1) . summaryLive)
        -- Settled on arrival and not taken: the epoch discards the result, and with it the resource.
        report ← advanceRequestEpoch (scheduledEndpoint owner)
        maybe False (const True) report `shouldBe` True
        awaitNote fixture "release r1"
        awaitLeaseSummary fixture "i" ((== 0) . summaryLive)

  describe "a required failure latched when the instance ends before it is applied" $ do
    it "fails a one-shot whose run returned after the failure became eligible" $ bounded $ do
      fixture ← newAFix 4
      onSubmit (afFake fixture) $ \submission →
        void (completeRequest (submissionCompletion submission) (ProviderExpected (ExpectedFailure "not_found" "gone" Nothing Nothing)))
      withBoundary $ \_ runtime → settleAll fixture $ do
        owner ← arrival fixture runtime "one shot"
        _ ← admitWith (afBase fixture) owner "o" (InstanceRequest (moduleNamed "oneshotstarter") RunOnce (Just "o") OrdinaryClass ["cmd", "tick"])
        settlement ← awaitSettled (afBase fixture) "o"
        case failureOf' settlement of
          Just failure → failureError failure `shouldSatisfy` (\err → case err of ErrorRequest _ _ → True; _ → False)
          Nothing → fail ("the instance did not fail: " <> show (resultOutcome settlement))

    it "fails an instance once when the dispatch applies it: the latch it keeps until the instance ends is not told again beside it" $ bounded $ do
      fixture ← newAFix 4
      withBoundary $ \_ runtime → settleAll fixture $ do
        owner ← arrival fixture runtime "applied"
        admitAdmitter fixture owner "i" "admitter"
        acommand fixture owner "i" "start" "a"
        awaitNote fixture "cmd start a started"
        answerExpected fixture 0 "not_found" >>= (`shouldBe` ReplySettled)
        settlement ← awaitSettled (afBase fixture) "i"
        case failureOf' settlement of
          Just failure → do
            (case failureError failure of ErrorRequest endpoint _ → endpoint; _ → "other") `shouldBe` "path"
            length (failureSecondary failure) `shouldBe` 0
          Nothing → fail ("the instance did not fail: " <> show (resultOutcome settlement))

    it "fails an instance that is stopped while the failure waits to be applied" $ bounded $ do
      fixture ← newAFix 4
      withBoundary $ \_ runtime → settleAll fixture $ do
        owner ← arrival fixture runtime "stopped"
        admitAdmitter fixture owner "i" "admitter"
        acommand fixture owner "i" "start" "a"
        awaitNote fixture "cmd start a started"
        acommand fixture owner "i" "block" "g"
        awaitEntered (sf (afBase fixture)) "g"
        answerExpected fixture 0 "not_found" >>= (`shouldBe` ReplySettled)
        _ ← expectControl (afBase fixture) owner "i" InstanceStop
        releaseGate (sf (afBase fixture)) "g"
        settlement ← awaitSettled (afBase fixture) "i"
        fmap (\failure → case failureError failure of ErrorRequest endpoint _ → endpoint; _ → "other") (failureOf' settlement) `shouldBe` Just "path"

  describe "a failure whose fields throw when they are first looked at" $ do
    it "is a provider defect when it is delivered after the submission, not an exception on the provider's thread" $ bounded $ do
      fixture ← newAFix 4
      setPolicy fixture (\held → held {polNecessity = OptionalRequest})
      ExceptionWithContext _ failure ← expectFatal $ \control runtime → settleAll fixture $ do
        owner ← arrival fixture runtime "lazy"
        admitAdmitter fixture owner "i" "admitter"
        acommand fixture owner "i" "start" "a"
        awaitNote fixture "cmd start a started"
        answerWith (afFake fixture) 0 (ProviderExpected (ExpectedFailure "not_found" "m" (Just (error "broken root")) Nothing)) >>= (`shouldBe` ReplyDefective)
        awaitScheduledTerminal control owner
      (fromException failure ∷ Maybe ProviderDefect) `shouldSatisfy` (/= Nothing)

  describe "a registry of request handles claimed by owners that start together" $ do
    it "serves exactly one of them, and refuses the others before anything starts" $ bounded $ do
      fixture ← newAFix 4
      withBoundary $ \_ runtime → settleAll fixture $ do
        let attempts = 16 ∷ Int
        results ← forM [1 .. attempts] $ \n → do
          done ← newEmptyMVar
          _ ←
            forkIO $
              tryExpected (startScheduledOwner runtime (admissionSpec fixture ("claim " <> Text.pack (show n)) [admitter] aConfig (admissionGrant fixture 8 SettleOnArrival) requiredPolicy))
                >>= putMVar done
          pure done
        outcomes ← mapM takeMVar results
        let started = [owner | Right (ScheduledStarted owner) ← outcomes]
            refused = [rendered | Left failure ← outcomes, let rendered = show failure, "the registry already serves an owner" `Text.isInfixOf` Text.pack rendered]
        (length started, length refused) `shouldBe` (1, attempts - 1)
