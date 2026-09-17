-- | Examples for the logger's filtering decision and the payload gating that
-- follows from it.
module Test.Foundation.Logging.Filtering (spec) where

import Control.Concurrent.MVar (modifyMVar_, newMVar, readMVar)
import Control.Monad (forM_)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Hetoimasia.Foundation.Log
import System.IO.Error (ioeGetErrorString)
import Test.Foundation.Logging.Support
  ( fixedMetadata
  , fixedThread
  , fixedTime
  , gameComponent
  , gpuComponent
  , newCollector
  , summaries
  , testComponent
  )
import Test.Hspec (Spec, describe, it, shouldBe, shouldReturn, shouldThrow)

spec ∷ Spec
spec = do
  describe "Logger filtering" $ do
    it "filters before invoking the sink" testFiltering
    it "suppresses everything when the master switch is off" testMasterSwitch
    it "applies the global threshold" testGlobalThreshold
    it "applies exact per-component thresholds" testComponentThreshold
    it "enables Debug only through the Debug selection" testDebugSelection
    it "preserves sink failures" testSinkFailure
  describe "Logger metadata" $
    it "gates payloads and providers for a suppressed entry" testGating

-- | Providers that also count how often each one was invoked.
countingMetadata ∷ IO (MetadataProviders, IO (Int, Int))
countingMetadata = do
  clockCalls ← newMVar (0 ∷ Int)
  threadCalls ← newMVar (0 ∷ Int)
  let bump counter = modifyMVar_ counter (pure . (+ 1))
      providers = MetadataProviders
        { metadataClock = bump clockCalls >> pure fixedTime
        , metadataThread = bump threadCalls >> pure fixedThread
        }
  pure (providers, (,) <$> readMVar clockCalls <*> readMVar threadCalls)

-- | Whether one entry reaches the sink under the given configuration.
emitsEntry ∷ LogFilter → LogLevel → Component → IO Bool
emitsEntry configuration level component = do
  (sink, collected) ← newCollector
  let logger = mkLoggerWith configuration fixedMetadata sink
  logEvent logger level component "probe" []
  not . null <$> collected

testFiltering ∷ IO ()
testFiltering = do
  (sink, collected) ← newCollector
  let logger =
        mkLoggerWith defaultLogFilter { filterGlobalLevel = Warning } fixedMetadata sink
  logDebug logger testComponent "hidden debug" []
  logInfo logger testComponent "hidden info" []
  logWarning logger (unsafeComponent "assets") "visible warning" []
  logError logger (unsafeComponent "render") "visible error" []
  summaries <$> collected `shouldReturn`
    [ (Warning, "assets", "visible warning")
    , (Error, "render", "visible error")
    ]

testMasterSwitch ∷ IO ()
testMasterSwitch = do
  -- Permissive in every other respect, so only the master switch can suppress.
  let configuration = defaultLogFilter
        { filterEnabled = False
        , filterGlobalLevel = Debug
        , filterDebug = DebugAll
        }
  forM_ [Debug, Info, Warning, Error] $ \level →
    emitsEntry configuration level gpuComponent `shouldReturn` False

testGlobalThreshold ∷ IO ()
testGlobalThreshold = do
  emitsEntry defaultLogFilter Info gpuComponent `shouldReturn` True
  emitsEntry defaultLogFilter Debug gpuComponent `shouldReturn` False
  let warning = defaultLogFilter { filterGlobalLevel = Warning }
  emitsEntry warning Info gpuComponent `shouldReturn` False
  emitsEntry warning Warning gpuComponent `shouldReturn` True
  emitsEntry warning Error gpuComponent `shouldReturn` True

testComponentThreshold ∷ IO ()
testComponentThreshold = do
  let configuration = defaultLogFilter
        { filterComponentLevels = Map.fromList [(gpuComponent, Error)]
        }
  -- The override applies to its exact component only.
  emitsEntry configuration Warning gpuComponent `shouldReturn` False
  emitsEntry configuration Error gpuComponent `shouldReturn` True
  emitsEntry configuration Info gameComponent `shouldReturn` True
  -- Matching is exact: a prefix of an overridden name is a different component.
  emitsEntry configuration Info (unsafeComponent "gpu") `shouldReturn` True

testDebugSelection ∷ IO ()
testDebugSelection = do
  -- A Debug threshold alone never enables Debug.
  let thresholdOnly = defaultLogFilter
        { filterComponentLevels = Map.fromList [(gpuComponent, Debug)]
        }
  emitsEntry thresholdOnly Debug gpuComponent `shouldReturn` False
  emitsEntry thresholdOnly Info gpuComponent `shouldReturn` True
  -- None, all, and an explicit set.
  emitsEntry defaultLogFilter { filterDebug = DebugNone } Debug gpuComponent
    `shouldReturn` False
  emitsEntry defaultLogFilter { filterDebug = DebugAll } Debug gpuComponent
    `shouldReturn` True
  emitsEntry defaultLogFilter { filterDebug = DebugAll } Debug gameComponent
    `shouldReturn` True
  let selected = defaultLogFilter { filterDebug = DebugComponents (Set.fromList [gpuComponent]) }
  emitsEntry selected Debug gpuComponent `shouldReturn` True
  emitsEntry selected Debug gameComponent `shouldReturn` False
  -- Selecting Debug for a component does not lift its other levels.
  emitsEntry selected Info gpuComponent `shouldReturn` True

testSinkFailure ∷ IO ()
testSinkFailure = do
  let logger = mkLoggerWith defaultLogFilter fixedMetadata
        (callbackSink (\_ → ioError (userError "sink unavailable")))
  logInfo logger testComponent "message" [] `shouldThrow`
    ((== "sink unavailable") . ioeGetErrorString)

testGating ∷ IO ()
testGating = do
  (sink, collected) ← newCollector
  (providers, counts) ← countingMetadata
  let logger = mkLoggerWith defaultLogFilter { filterGlobalLevel = Warning } providers sink
  -- A suppressed entry forces neither payload and calls neither provider.
  logInfo logger testComponent (error "message must not be forced")
    [("field", error "field must not be forced")]
  collected `shouldReturn` []
  counts `shouldReturn` (0, 0)
  -- An emitted entry calls each provider once and carries exactly their values.
  logWarning logger testComponent "emitted" []
  counts `shouldReturn` (1, 1)
  entries ← collected
  map entryTime entries `shouldBe` [fixedTime]
  map entryThread entries `shouldBe` [fixedThread]
