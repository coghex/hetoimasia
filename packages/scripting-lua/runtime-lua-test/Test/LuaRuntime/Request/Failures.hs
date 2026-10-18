-- | Failure handling: a provider reporting a failure settles the request as data; provider
-- code raising when the engine calls it is a failure of application code, a failure of the host
-- under the owner's policy, unconverted; a failure in a provider's retirement is a cleanup
-- failure, fatal under every policy; simultaneous failures keep the first as primary and the
-- others whole as evidence; and a provider's completion never blocks.
module Test.LuaRuntime.Request.Failures (spec) where

import Control.Exception (ExceptionWithContext (ExceptionWithContext), SomeException, throwIO, toException)
import Control.Monad (forM_)
import qualified Data.Text as Text
import Hetoimasia.Foundation.Resource (cleanupFailureException, cleanupFailureLabel, cleanupFailuresInContext)
import Hetoimasia.Runtime.Supervision (WorkerStatus (WorkerUnavailable))
import Hetoimasia.Scripting.Lua.Instance
import Hetoimasia.Scripting.Lua.Provider
import Hetoimasia.Scripting.Lua.Scheduled
import Test.Hspec (Spec, describe, it, shouldBe, shouldSatisfy)
import Test.LuaRuntime.Instance.Support
import Test.LuaRuntime.Request.Support
import Test.LuaRuntime.Scheduled.Support (awaitEntered, awaitScheduledTerminal, releaseGate)
import Test.LuaRuntime.Support (Broken (Broken), bounded, brokenIs, expectFatal, optionalPolicy, requiredPolicy, withBoundary)

-- | Whether a retained failure is the application's own, of this name.
brokenAmong ∷ Text.Text → ExceptionWithContext SomeException → Bool
brokenAmong name (ExceptionWithContext _ failure) = brokenIs name failure

spec ∷ Spec
spec = describe "failures" $ do
  describe "a provider that raises when handed a request" $ do
    it "is a failure of the host, unconverted, under a required policy, and the request is taken back" $ bounded $ do
      fixture ← newIFixture
      fake ← newFake
      onSubmit fake (\_ → throwIO (Broken "submit"))
      ExceptionWithContext _ failure ← expectFatal $ \control runtime → providersFinish fake $ do
        owner ← startRequester fixture runtime "required" [asker] cmdConfig (grantOf fake 4) requiredPolicy
        admitAsker fixture owner "i" "asker"
        command fixture owner "i" "start" "a"
        awaitScheduledTerminal control owner
      failure `shouldSatisfy` brokenIs "submit"

    it "ends only an optional owner whose classifier recognizes it, as unavailable with its own type, and holds nothing" $ bounded $ do
      fixture ← newIFixture
      fake ← newFake
      onSubmit fake (\_ → throwIO (Broken "submit"))
      withBoundary $ \control runtime → providersFinish fake $ do
        owner ← startRequester fixture runtime "optional" [asker] cmdConfig (grantOf fake 4) (optionalPolicy (brokenIs "submit"))
        admitAsker fixture owner "i" "asker"
        command fixture owner "i" "start" "a"
        awaitScheduledTerminal control owner >>= \case
          WorkerUnavailable (ExceptionWithContext _ failure) → failure `shouldSatisfy` brokenIs "submit"
          other → fail ("expected an unavailable owner, found " <> show other)
        submissions fake >>= (`shouldBe` 0)
        d ← diagnostics owner
        -- Admitted, and taken back: nothing is held for a request that never reached its provider.
        (rdAdmitted d, rdOutstanding d, rdInvalidated d) `shouldBe` (1, 0, 0)

  describe "a provider that raises when told interest was withdrawn" $ do
    it "is a failure of the host when the script's cancel told it" $ bounded $ do
      fixture ← newIFixture
      fake ← newFake
      onCancel fake (\_ → throwIO (Broken "cancel"))
      ExceptionWithContext _ failure ← expectFatal $ \control runtime → providersFinish fake $ do
        owner ← startRequester fixture runtime "cancel" [asker] cmdConfig (grantOf fake 4) requiredPolicy
        admitAsker fixture owner "i" "asker"
        command fixture owner "i" "start" "a"
        awaitLine fixture "cmd start a started"
        command fixture owner "i" "cancel" "a"
        -- The owner is failing, and stays live until the provider says its work is over.
        awaitCancelled fake 1
        finishWork fake 0
        awaitScheduledTerminal control owner
      failure `shouldSatisfy` brokenIs "cancel"
      cancelledOrder fake >>= (`shouldBe` [0])

    it "keeps the first as the owner's failure and the rest whole as cleanup evidence when several raise together" $ bounded $ do
      fixture ← newIFixture
      fake ← newFake
      onCancel fake (\index → throwIO (Broken ("cancel " <> Text.pack (show index))))
      ExceptionWithContext context failure ← expectFatal $ \control runtime → providersFinish fake $ do
        owner ← startRequester fixture runtime "together" [asker] cmdConfig (grantOf fake 4) (optionalPolicy (const True))
        admitAsker fixture owner "i" "asker"
        command fixture owner "i" "start" "a"
        awaitLine fixture "cmd start a started"
        command fixture owner "i" "start" "b"
        awaitLine fixture "cmd start b started"
        _ ← expectControl fixture owner "i" InstanceStop
        awaitCancelled fake 2
        finishWork fake 0
        finishWork fake 1
        awaitScheduledTerminal control owner
      failure `shouldSatisfy` brokenIs "cancel 0"
      let evidence = [(cleanupFailureLabel found, cleanupFailureException found) | found ← cleanupFailuresInContext context]
      map fst evidence `shouldSatisfy` elem "lua request cancel"
      [exception | ("lua request cancel", exception) ← evidence] `shouldSatisfy` any (brokenAmong "cancel 1")
      -- Both were told, whatever the first raised.
      cancelledOrder fake >>= (`shouldBe` [0, 1])

  describe "a provider's retirement that fails" $ do
    it "is retained as cleanup evidence, fatal under a required and under an optional policy alike" $ bounded $ do
      forM_ [("required", requiredPolicy), ("optional", optionalPolicy (const True))] $ \(label, policy) → do
        fixture ← newIFixture
        fake ← newFake
        ExceptionWithContext context _ ← expectFatal $ \control runtime → providersFinish fake $ do
          owner ← startRequester fixture runtime ("retirement " <> label) [asker] cmdConfig (grantOf fake 4) policy
          admitAsker fixture owner "i" "asker"
          command fixture owner "i" "start" "a"
          awaitLine fixture "cmd start a started"
          command fixture owner "i" "cancel" "a"
          awaitLine fixture "cmd cancel a cancelled"
          failWorkWith fake 0 (toException (Broken "retirement"))
          awaitScheduledTerminal control owner
        let evidence = [(cleanupFailureLabel found, cleanupFailureException found) | found ← cleanupFailuresInContext context]
        map fst evidence `shouldSatisfy` any (Text.isInfixOf "path request")
        map snd evidence `shouldSatisfy` any (brokenAmong "retirement")

    it "keeps what the work needed undisposed of: a dependency is never released under work that failed" $ bounded $ do
      fixture ← newIFixture
      fake ← newFake
      _ ← expectFatal $ \control runtime → providersFinish fake $ do
        owner ← startRequester fixture runtime "dependency" [asker] cmdConfig (grantOf fake 4) requiredPolicy
        admitAsker fixture owner "i" "asker"
        commandFrom fixture owner "i" "start" "a" Nothing (Just 3)
        awaitLine fixture "cmd start a started"
        command fixture owner "i" "cancel" "a"
        awaitLine fixture "cmd cancel a cancelled"
        failWorkWith fake 0 (toException (Broken "retirement"))
        awaitScheduledTerminal control owner
      linesOf fixture >>= (`shouldSatisfy` notElem "disposed 3")

  describe "a provider's completion" $ do
    it "never waits for the owner: it completes while the owner is inside a segment and the owner's places are all held" $ bounded $ do
      fixture ← newIFixture
      fake ← newFake
      withBoundary $ \_ runtime → providersFinish fake $ do
        owner ← startRequester fixture runtime "busy" [asker] cmdConfig (grantOf fake 1) requiredPolicy
        admitAsker fixture owner "i" "asker"
        command fixture owner "i" "start" "a"
        awaitLine fixture "cmd start a started"
        -- Every place is held, and the owner is held inside a segment.
        command fixture owner "i" "block" "gate"
        awaitEntered (ifBase fixture) "gate"
        answerResult fake 0 5 >>= (`shouldBe` ReplySettled)
        answerResult fake 0 6 >>= (`shouldBe` ReplyLate)
        releaseGate (ifBase fixture) "gate"
        awaitLine fixture "cmd block gate unblocked"
        command fixture owner "i" "take" "a"
        awaitLine fixture "cmd take a {status=result,value=5}"

    it "is refused as unknown, counted, once the owner has exited" $ bounded $ do
      fixture ← newIFixture
      fake ← newFake
      withBoundary $ \control runtime → providersFinish fake $ do
        owner ← startRequester fixture runtime "exited" [asker] cmdConfig (grantOf fake 4) requiredPolicy
        admitAsker fixture owner "i" "asker"
        command fixture owner "i" "start" "a"
        awaitLine fixture "cmd start a started"
        retireScheduled owner
        awaitCancelled fake 1
        finishWork fake 0
        _ ← awaitScheduledTerminal control owner
        answerResult fake 0 1 >>= (`shouldSatisfy` (`elem` [ReplyUnknown, ReplyLate]))
