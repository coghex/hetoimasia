-- | Examples for 'runApplication'.
--
-- The logger fixtures come from the logging component that owns them, so the
-- runtime examples observe the same collector the logging examples do.
module Test.Runtime.Application (spec) where

import Hetoimasia.Foundation.Log
import Hetoimasia.Runtime (runApplication)
import System.IO.Error (ioeGetErrorString)
import Test.Runtime.LogFixture (fixedMetadata, newCollector, summaries)
import Test.Hspec (Spec, describe, it, shouldBe, shouldReturn, shouldThrow)

spec ∷ Spec
spec = describe "runApplication" $ do
  it "orders events and returns the application result" testRuntime
  it "propagates failure without reporting completion" testRuntimeFailure

testRuntime ∷ IO ()
testRuntime = do
  (sink, collected) ← newCollector
  let logger = mkLoggerWith defaultLogFilter fixedMetadata sink
  result ← runApplication logger "test" $ do
    logInfo logger (unsafeComponent "application") "tick" []
    pure (42 ∷ Int)
  result `shouldBe` 42
  summaries <$> collected `shouldReturn`
    [ (Info, "runtime", "Starting test")
    , (Info, "application", "tick")
    , (Info, "runtime", "Completed test")
    ]

testRuntimeFailure ∷ IO ()
testRuntimeFailure = do
  (sink, collected) ← newCollector
  let logger = mkLoggerWith defaultLogFilter fixedMetadata sink
  runApplication logger "test" (ioError (userError "application failed")) `shouldThrow`
    ((== "application failed") . ioeGetErrorString)
  summaries <$> collected `shouldReturn` [(Info, "runtime", "Starting test")]
