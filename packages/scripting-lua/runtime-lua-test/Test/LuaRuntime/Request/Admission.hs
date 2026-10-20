-- | Admission: a request binding is callable where the owner was granted a request service and
-- nowhere else; a place is reserved before the provider is asked anything; and a request that
-- cannot be admitted is refused as a fault of the call, never a failure of the host, with the
-- provider asked nothing.
module Test.LuaRuntime.Request.Admission (spec) where

import Control.Exception (ExceptionWithContext (ExceptionWithContext), SomeException, tryWithContext)
import qualified Data.Text as Text
import Hetoimasia.Foundation.Resource (cleanupFailureLabel, cleanupFailuresInContext)
import Hetoimasia.Scripting.Lua.Instance
import Hetoimasia.Scripting.Lua.Owner (BoundaryFault (boundaryReason), FaultReason (NotYetSupported))
import Hetoimasia.Scripting.Lua.Provider
import Hetoimasia.Scripting.Lua.Registration
import Hetoimasia.Scripting.Lua.Request
import Hetoimasia.Scripting.Lua.Runtime (CallFault (BoundaryFailed))
import Hetoimasia.Scripting.Lua.Scheduled
import Hetoimasia.Scripting.Lua.Value
import Data.Text (Text)
import Test.Hspec (Spec, describe, it, shouldBe, shouldSatisfy)
import Test.LuaRuntime.Instance.Support
import Test.LuaRuntime.Request.Support
import Test.LuaRuntime.Scheduled.Support (awaitEffect, awaitEntered, awaitScheduledTerminal, releaseGate, withChunks)
import Test.LuaRuntime.Support (Gated (..), bounded, expectFatal, optionalPolicy, requiredPolicy, withBoundary, withBoundaryOpening)
import qualified Data.Text.Encoding as Text
import Hetoimasia.Scripting.Lua.Owner (chunkName)

-- | The reason a call was not delivered, if it was not.
unsupportedOf ∷ IFixture → Text → IO (Maybe FaultReason)
unsupportedOf fixture name = do
  settled ← awaitSettled fixture name
  pure $ do
    failure ← failureOf' settled
    case failureError failure of
      ErrorFault (BoundaryFailed fault) | reason@(NotYetSupported _) ← boundaryReason fault → Just reason
      _ → Nothing

spec ∷ Spec
spec = describe "admission" $ do
  it "reserves a place before the provider is asked, and refuses past the bound as a fault of the call" $ bounded $ do
    fixture ← newIFixture
    fake ← newFake
    withBoundary $ \_ runtime → providersFinish fake $ do
      owner ← startRequester fixture runtime "bound" [asker] cmdConfig (grantOf fake 1) requiredPolicy
      admitAsker fixture owner "i" "asker"
      command fixture owner "i" "start" "a"
      awaitLine fixture "cmd start a started"
      command fixture owner "i" "start" "b"
      -- The refusal fails the call and so the instance, whose request is revoked and its
      -- provider told; the instance settles once that provider proves its work over.
      awaitCancelled fake 1
      finishWork fake 0
      refusalOf fixture "i" >>= (`shouldBe` Just "request refused: all 1 places are held")
      -- The provider was asked about one request, and the refusal was no failure of the host.
      submissions fake >>= (`shouldBe` 1)
      d ← diagnostics owner
      (rdAdmitted d, rdRefused d) `shouldBe` (1, 1)

  it "keeps a cancelled request's place charged until the provider proves its work over" $ bounded $ do
    fixture ← newIFixture
    fake ← newFake
    withBoundary $ \_ runtime → providersFinish fake $ do
      owner ← startRequester fixture runtime "charged" [asker] cmdConfig (grantOf fake 1) requiredPolicy
      admitAsker fixture owner "i" "asker"
      command fixture owner "i" "start" "a"
      awaitLine fixture "cmd start a started"
      command fixture owner "i" "cancel" "a"
      awaitLine fixture "cmd cancel a cancelled"
      command fixture owner "i" "take" "a"
      awaitLine fixture "cmd take a {reason=owner,status=cancelled}"
      cancelledOrder fake >>= (`shouldBe` [0])
      -- Settled and taken, and the provider has not said its work is over.
      d ← diagnostics owner
      (rdOutstanding d, rdWorkPending d) `shouldBe` (1, 1)
      admitAsker fixture owner "j" "asker"
      command fixture owner "j" "start" "b"
      refusalOf fixture "j" >>= (`shouldBe` Just "request refused: all 1 places are held")
      submissions fake >>= (`shouldBe` 1)
      finishWork fake 0
      awaitDiagnostic owner ((== 0) . rdOutstanding)
      admitAsker fixture owner "k" "asker"
      command fixture owner "k" "start" "c"
      awaitLine fixture "cmd start c started"

  it "admits in init, where the instance is taking requests" $ bounded $ do
    fixture ← newIFixture
    fake ← newFake
    withBoundary $ \_ runtime → providersFinish fake $ do
      owner ← startRequester fixture runtime "init" [initAsker] cmdConfig (grantOf fake 4) requiredPolicy
      admitAsker fixture owner "i" "initasker"
      awaitLine fixture "init started"
      submissions fake >>= (`shouldBe` 1)

  it "refuses a request made in shutdown, which is past taking requests, without asking the provider" $ bounded $ do
    fixture ← newIFixture
    fake ← newFake
    withBoundary $ \_ runtime → providersFinish fake $ do
      owner ← startRequester fixture runtime "shutdown" [shutdownAsker] cmdConfig (grantOf fake 4) requiredPolicy
      admitAsker fixture owner "i" "shutdownasker"
      settleControl fixture owner "i" InstanceStop >>= (`shouldBe` ControlApplied)
      refusalOf fixture "i" >>= (`shouldBe` Just "request refused: the owner is no longer taking requests")
      submissions fake >>= (`shouldBe` 0)
      -- The hook's own record before the request, and none after it.
      linesOf fixture >>= (`shouldSatisfy` (\recorded → "shutdown stopped" `elem` recorded && "shutdown after" `notElem` recorded))

  it "refuses a request once the owner has been asked to stop, without asking the provider" $ bounded $ do
    fixture ← newIFixture
    fake ← newFake
    withBoundaryOpening [openAllGates fixture] $ \control runtime → providersFinish fake $ do
      owner ← startRequester fixture runtime "stopping" [asker] cmdConfig (grantOf fake 4) requiredPolicy
      admitAsker fixture owner "i" "asker"
      command fixture owner "i" "block_start" "gate"
      awaitEntered (ifBase fixture) "gate"
      retireScheduled owner
      releaseGate (ifBase fixture) "gate"
      refusalOf fixture "i" >>= (`shouldBe` Just "request refused: the owner is no longer taking requests")
      submissions fake >>= (`shouldBe` 0)
      _ ← awaitScheduledTerminal control owner
      pure ()

  it "refuses a request made by a closing handler of a coroutine being closed, without asking the provider again" $ bounded $ do
    fixture ← newIFixture
    fake ← newFake
    ExceptionWithContext context _ ← expectFatal $ \control runtime → providersFinish fake $ do
      owner ← startRequester fixture runtime "closing" [closingAsker] cmdConfig (grantOf fake 4) (optionalPolicy (const True))
      admitAsker fixture owner "i" "closingasker"
      command fixture owner "i" "start" "a"
      awaitLine fixture "waiting a"
      awaitSubmitted fake 1
      _ ← askControl fixture owner "i" InstanceStop
      -- The handler ran as the coroutine was closed, and its refusal is its fault: what closing
      -- a coroutine raises is cleanup evidence that ends the owner. The provider is told its
      -- one request was dropped, and the owner leaves once it says it is done with it.
      awaitCancelled fake 1
      awaitEffect (ifBase fixture) "closing"
      submissions fake >>= (`shouldBe` 1)
      finishWork fake 0
      awaitScheduledTerminal control owner
    map cleanupFailureLabel (cleanupFailuresInContext context) `shouldSatisfy` elem "lua task close"
    linesOf fixture >>= (`shouldSatisfy` notElem "closing after")

  it "refuses a request when no instance or task is running to receive the answer, as a fault of the call" $ bounded $ do
    fixture ← newIFixture
    fake ← newFake
    let source = "rq.start('path', 1)"
    outcome ← tryWithContext @SomeException $ withBoundary $ \_ runtime → providersFinish fake $ do
      let spec' = withChunks [(chunkName "init", Text.encodeUtf8 source)] (requestSpec fixture "nobody" [asker] cmdConfig (grantOf fake 4) requiredPolicy)
      startRequesterWith fixture runtime spec'
    case outcome of
      Left (ExceptionWithContext _ failure) → show failure `shouldSatisfy` Text.isInfixOf "no instance or task is running" . Text.pack
      Right _ → fail "expected the initial chunk's request refused"
    submissions fake >>= (`shouldBe` 0)

  it "answers an endpoint the grant does not name as the application's own mistake, a failure of the host" $ bounded $ do
    fixture ← newIFixture
    fake ← newFake
    ExceptionWithContext _ failure ← expectFatal $ \control runtime → providersFinish fake $ do
      owner ← startRequester fixture runtime "unnamed" [asker] cmdConfig (grantOf fake 4) requiredPolicy
      admitAsker fixture owner "i" "asker"
      command fixture owner "i" "unnamed" "a"
      awaitScheduledTerminal control owner
    show failure `shouldSatisfy` Text.isInfixOf "the grant names no such endpoint" . Text.pack

  it "refuses the handle of another instance, and a handle whose settlement was taken, as faults of the call" $ bounded $ do
    fixture ← newIFixture
    fake ← newFake
    withBoundary $ \_ runtime → providersFinish fake $ do
      owner ← startRequester fixture runtime "handles" [asker] cmdConfig (grantOf fake 4) requiredPolicy
      admitAsker fixture owner "owner" "asker"
      admitAsker fixture owner "stranger" "asker"
      admitAsker fixture owner "again" "asker"
      command fixture owner "owner" "start" "a"
      awaitLine fixture "cmd start a started"
      command fixture owner "owner" "stash" "a"
      awaitLine fixture "cmd stash a stashed"
      command fixture owner "stranger" "other" "a"
      -- The instance that made the request lost nothing to the stranger's refusal; the
      -- stranger fails, and has nothing outstanding to wait for.
      refusalOf fixture "stranger" >>= (`shouldBe` Just "request refused: the handle belongs to another requester")
      -- Taking once retires the handle: a second look at it is refused.
      _ ← answerResult fake 0 5
      command fixture owner "again" "start" "c"
      awaitLine fixture "cmd start c started"
      _ ← answerResult fake 1 6
      command fixture owner "again" "take" "c"
      awaitLine fixture "cmd take c {status=result,value=6}"
      command fixture owner "again" "take" "c"
      refusalOf fixture "again" >>= (`shouldBe` Just "request refused: the handle names no request that is still held")

  describe "an owner granted no request service" $ do
    it "keeps every request and a wait for one answering not yet supported, and runs no provider code" $ bounded $ do
      fixture ← newIFixture
      fake ← newFake
      withBoundary $ \_ runtime → providersFinish fake $ do
        let ungranted = (requestSpec fixture "ungranted" [asker] cmdConfig (grantOf fake 4) requiredPolicy) {scheduledRequests = Nothing}
        owner ← startRequesterWith fixture runtime ungranted
        admitAsker fixture owner "starts" "asker"
        admitAsker fixture owner "waits" "asker"
        command fixture owner "starts" "start" "a"
        unsupportedOf fixture "starts" >>= (`shouldBe` Just (NotYetSupported AsynchronousNativeRequest))
        command fixture owner "waits" "wait" "a"
        unsupportedOf fixture "waits" >>= (`shouldBe` Just (NotYetSupported SchedulerOperation))
        submissions fake >>= (`shouldBe` 0)

  describe "a finalizer" $ do
    it "cannot start a request: the call is refused before dispatch, and an asynchronous binding cannot be declared finalizer-eligible" $ bounded $ do
      fixture ← newIFixture
      fake ← newFake
      let source = "collectgarbage('stop') keep_alive = setmetatable({}, {__gc = function() rq.start('path', 1) end})"
      ExceptionWithContext context _ ← expectFatal $ \control runtime → providersFinish fake $ do
        let spec' = withChunks [(chunkName "init", Text.encodeUtf8 source)] (requestSpec fixture "finalizing" [asker] cmdConfig (grantOf fake 4) (optionalPolicy (const True)))
        owner ← startRequesterWith fixture runtime spec'
        retireScheduled owner
        awaitScheduledTerminal control owner
      map cleanupFailureLabel (cleanupFailuresInContext context) `shouldSatisfy` elem "lua finalizer refused"
      submissions fake >>= (`shouldBe` 0)
      let refused binding = case registration [requestHandleType "request"] [namespace "n" [finalizerEligible binding]] of
            Left (FinalizerCannotStartWork _) → pure ()
            other → fail ("expected the finalizer eligibility refused, found " <> either show (const "a registration") other)
          requests = [binding | binding ← requestBindings "request" SInteger, bindingKind binding == AsynchronousNativeRequest]
      refused (asynchronousNativeRequestIn "start" [] [] (\_ _ → pure []))
      length requests `shouldBe` 3
      mapM_ refused requests
