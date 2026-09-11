module Main (main) where

import Data.IORef (newIORef, modifyIORef', readIORef)
import Hetoimasia.Foundation.Log
import Hetoimasia.Runtime (runApplication)
import System.IO.Error (ioeGetErrorString)
import Test.Hspec (describe, hspec, it, shouldBe, shouldReturn, shouldThrow)

main ∷ IO ()
main = hspec $ do
  describe "Logger" $ do
    it "filters before invoking the sink" testFiltering
    it "preserves sink failures" testSinkFailure
  describe "runApplication" $ do
    it "orders events and returns the application result" testRuntime
    it "propagates failure without reporting completion" testRuntimeFailure

testFiltering ∷ IO ()
testFiltering = do
  entries ← newIORef []
  let logger = mkLogger Warning (\entry → modifyIORef' entries (entry :))
  logMessage logger Debug "test" "hidden debug"
  logMessage logger Info "test" "hidden info"
  logMessage logger Warning "assets" "visible warning"
  logMessage logger Error "render" "visible error"
  (reverse <$> readIORef entries) `shouldReturn`
    [LogEntry Warning "assets" "visible warning", LogEntry Error "render" "visible error"]

testSinkFailure ∷ IO ()
testSinkFailure = do
  let logger = mkLogger Info (\_ → ioError (userError "sink unavailable"))
  logMessage logger Info "test" "message" `shouldThrow`
    ((== "sink unavailable") . ioeGetErrorString)

testRuntime ∷ IO ()
testRuntime = do
  entries ← newIORef []
  let logger = mkLogger Info (\entry → modifyIORef' entries (entry :))
  result ← runApplication logger "test" $ do
    logMessage logger Info "application" "tick"
    pure (42 ∷ Int)
  result `shouldBe` 42
  (reverse <$> readIORef entries) `shouldReturn`
    [ LogEntry Info "runtime" "Starting test"
    , LogEntry Info "application" "tick"
    , LogEntry Info "runtime" "Completed test"
    ]

testRuntimeFailure ∷ IO ()
testRuntimeFailure = do
  entries ← newIORef []
  let logger = mkLogger Info (\entry → modifyIORef' entries (entry :))
  runApplication logger "test" (ioError (userError "application failed")) `shouldThrow`
    ((== "application failed") . ioeGetErrorString)
  readIORef entries `shouldReturn` [LogEntry Info "runtime" "Starting test"]
