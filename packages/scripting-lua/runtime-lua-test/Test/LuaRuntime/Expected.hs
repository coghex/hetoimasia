-- | What an example that expects the supervised boundary, or a wait, to fail may not take for
-- that failure: a failed assertion of the example, or the example's bound expiring. Each shared
-- helper that expects such a failure ends the example with the assertion's own message and
-- source location, or with the timeout, and answers no outcome and runs nothing after it; and it
-- still answers the application's own failures, injected ones among them.
module Test.LuaRuntime.Expected (spec) where

import Control.Concurrent.MVar (newEmptyMVar, takeMVar)
import Control.Exception (ExceptionWithContext (ExceptionWithContext), SomeException, throwIO, toException, try)
import Control.Monad (forM_, void)
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.List (isSuffixOf)
import GHC.Stack (SrcLoc (srcLocFile))
import Hetoimasia.Runtime.Supervision (Recognition (Recognized, Unrecognized), RuntimeControl, WorkerPolicy (policyClassifier))
import Hetoimasia.Scripting.Lua.Runtime (LuaRuntime, OwnerStart (OwnerRejected))
import System.Timeout (timeout)
import Test.HUnit.Lang (FailureReason (Reason), HUnitFailure (HUnitFailure))
import Test.Hspec (Spec, describe, expectationFailure, it, shouldBe, shouldSatisfy)
import Test.LuaRuntime.Accounting.Support (failingWait)
import Test.LuaRuntime.Scheduled.Support (newSFixture)
import Test.LuaRuntime.Support

-- | A helper that expects a boundary to fail, as a function of the body it runs there. What it
-- answers is dropped, so that the examples ask only what it does with what ends the body.
type Helper = (RuntimeControl → LuaRuntime → IO ()) → IO ()

helpers ∷ [(String, Helper)]
helpers =
  [ ("expectFatal", void . expectFatal)
  , ("expectFatalOpening", void . expectFatalOpening [])
  , ("tryBoundaryOpening", void . tryBoundaryOpening [])
  , ("tryExpected over a boundary", \body → void (tryExpected (withBoundary body)))
  , ("failingWait", \body → newSFixture >>= \fixture → failingWait fixture [] (\control runtime → body control runtime >> failExample "the scenario returned"))
  ]

-- | A helper that answers the failure it expected, as a function of the body it runs in a boundary.
type Answering = (RuntimeControl → LuaRuntime → IO ()) → IO (Maybe SomeException)

answering ∷ [(String, Answering)]
answering =
  [ ("expectFatal", \body → Just . failureOf' <$> expectFatal body)
  , ("expectFatalOpening", \body → Just . failureOf' <$> expectFatalOpening [] body)
  , ("tryBoundaryOpening", \body → either (Just . failureOf') (const Nothing) <$> tryBoundaryOpening [] body)
  , ("tryExpected over a boundary", \body → either (Just . failureOf') (const Nothing) <$> tryExpected (withBoundary body))
  ]
  where
    failureOf' (ExceptionWithContext _ failure) = failure

-- | Whether the example failed as an assertion with this message, raised in a source file
-- ending in this path.
assertionAt ∷ String → FilePath → Either HUnitFailure () → Bool
assertionAt message file = \case
  Left (HUnitFailure (Just location) (Reason found)) → found == message && file `isSuffixOf` srcLocFile location
  _ → False

spec ∷ Spec
spec = describe "the helpers that expect a boundary or a wait to fail" $ do
  forM_ helpers $ \(name, run) → describe name $ do
    it "ends the example with a failed assertion raised inside the boundary, as itself, with its message and location" $ bounded $ do
      failure ← try @HUnitFailure (run (\_ _ → expectationFailure "inside the boundary"))
      failure `shouldSatisfy` assertionAt "inside the boundary" "Test/LuaRuntime/Expected.hs"

    it "ends the example with the assertion a fixture helper raises inside the boundary, with its message and the location in the helper" $ bounded $ do
      failure ← try @HUnitFailure (run (\_ _ → void (expectOwner OwnerRejected)))
      failure `shouldSatisfy` assertionAt "expected an owner, found the boundary closed" "Test/LuaRuntime/Support.hs"

    it "answers no outcome and runs nothing after it when the example's bound expires inside the boundary" $ bounded $ do
      continued ← newIORef False
      expired ← timeout 20000 (run (\_ _ → newEmptyMVar @() >>= takeMVar) >> writeIORef continued True)
      expired `shouldBe` Nothing
      readIORef continued >>= (`shouldBe` False)

  forM_ answering $ \(name, run) → describe name $
    it "still answers the application's own failures, a typed one and an injected user error among them" $ bounded $ do
      typed ← run (\_ _ → throwIO (Broken "injected"))
      typed `shouldSatisfy` maybe False (brokenIs "injected")
      injected ← run (\_ _ → ioError (userError "injected"))
      fmap show injected `shouldBe` Just (show (userError "injected"))

  describe "an optional worker's policy" $
    it "recognizes what it says it does, and never a failed assertion, which is fatal" $ bounded $ do
      ExceptionWithContext context _ ← expectFatal (\_ _ → throwIO (Broken "injected"))
      let classify ∷ SomeException → IO Recognition
          classify failure = policyClassifier (optionalPolicy (const True)) (ExceptionWithContext context failure)
      classify (toException (Broken "injected")) >>= (`shouldBe` Recognized)
      classify (toException (HUnitFailure Nothing (Reason "an assertion"))) >>= (`shouldBe` Unrecognized)
