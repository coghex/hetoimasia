module Main (main) where

import Control.Concurrent (forkIO, myThreadId)
import Control.Concurrent.MVar
  ( MVar
  , modifyMVar_
  , newEmptyMVar
  , newMVar
  , putMVar
  , readMVar
  , takeMVar
  )
import Control.Monad (forM_, void)
import Data.Either (isLeft)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Time.Calendar (fromGregorian)
import Data.Time.Clock (UTCTime (UTCTime), secondsToDiffTime)
import GHC.Stack
  ( CallStack
  , HasCallStack
  , callStack
  , getCallStack
  , srcLocFile
  , srcLocStartLine
  )
import Hetoimasia.Foundation.Log
import Hetoimasia.Runtime (runApplication)
import System.IO.Error (ioeGetErrorString)
import Test.Hspec (describe, hspec, it, shouldBe, shouldNotBe, shouldReturn, shouldSatisfy, shouldThrow)

main ∷ IO ()
main = hspec $ do
  describe "Component" $ do
    it "accepts lowercase dotted names" testComponentAccepted
    it "rejects malformed and reserved names" testComponentRejected
  describe "Logger filtering" $ do
    it "filters before invoking the sink" testFiltering
    it "suppresses everything when the master switch is off" testMasterSwitch
    it "applies the global threshold" testGlobalThreshold
    it "applies exact per-component thresholds" testComponentThreshold
    it "enables Debug only through the Debug selection" testDebugSelection
    it "preserves sink failures" testSinkFailure
  describe "Logger metadata" $ do
    it "gates payloads and providers for a suppressed entry" testGating
  describe "Logger context" $ do
    it "resolves field precedence and breadcrumb order" testContextPrecedence
    it "keeps concurrent worker context and thread identity separate" testConcurrentContext
  describe "Logger source attribution" $ do
    it "reports the call site outside a wrapper" testSourceThroughWrapper
    it "reports no location when the source switch is off" testSourceDisabled
  describe "runApplication" $ do
    it "orders events and returns the application result" testRuntime
    it "propagates failure without reporting completion" testRuntimeFailure

-- Fixtures -------------------------------------------------------------------

testComponent ∷ Component
testComponent = unsafeComponent "test"

gpuComponent ∷ Component
gpuComponent = unsafeComponent "gpu.vulkan"

gameComponent ∷ Component
gameComponent = unsafeComponent "game.world"

fixedTime ∷ UTCTime
fixedTime = UTCTime (fromGregorian 2026 9 10) (secondsToDiffTime 43200)

fixedThread ∷ Text
fixedThread = "ThreadId-fixture"

-- | Providers returning values a test can assert on exactly.
fixedMetadata ∷ MetadataProviders
fixedMetadata = MetadataProviders
  { metadataClock = pure fixedTime
  , metadataThread = pure fixedThread
  }

-- | A sink collecting entries in emission order, usable from several threads.
newCollector ∷ IO (LogSink, IO [LogEntry])
newCollector = do
  collected ← newMVar []
  let sink entry = modifyMVar_ collected (pure . (entry :))
  pure (sink, reverse <$> readMVar collected)

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

-- | Level, component, and message of each entry, ignoring metadata.
summaries ∷ [LogEntry] → [(LogLevel, Text, Text)]
summaries = map summary
  where
    summary entry =
      (entryLevel entry, componentText (entryComponent entry), entryMessage entry)

-- Components -----------------------------------------------------------------

testComponentAccepted ∷ IO ()
testComponentAccepted =
  map (fmap componentText . mkComponent) ["gpu.vulkan", "game.world", "lua"]
    `shouldBe` [Right "gpu.vulkan", Right "game.world", Right "lua"]

testComponentRejected ∷ IO ()
testComponentRejected =
  forM_ ["Gpu.Vulkan", "gpu..vulkan", "gpu.", "1gpu", " gpu", "", "all", "none"] $ \name → do
    mkComponent name `shouldSatisfy` isLeft
    -- The rejection is descriptive: it quotes the offending name.
    case mkComponent name of
      Right _ → fail ("accepted " <> show name)
      Left reason → reason `shouldSatisfy` Text.isInfixOf ("\"" <> name <> "\"")

-- Filtering ------------------------------------------------------------------

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
  let logger =
        mkLoggerWith defaultLogFilter fixedMetadata (\_ → ioError (userError "sink unavailable"))
  logInfo logger testComponent "message" [] `shouldThrow`
    ((== "sink unavailable") . ioeGetErrorString)

-- Metadata gating ------------------------------------------------------------

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

-- Scoped context -------------------------------------------------------------

testContextPrecedence ∷ IO ()
testContextPrecedence = do
  (sink, collected) ← newCollector
  let root = mkLoggerWith defaultLogFilter fixedMetadata sink
      outer = withBreadcrumb "startup" (withFields [("service", "engine"), ("scope", "outer")] root)
      inner = withBreadcrumb "worker" (withFields [("scope", "inner")] outer)
  logInfo inner testComponent "inherited" []
  logInfo inner testComponent "overridden" [("scope", "event")]
  -- Deriving never mutates the parent.
  logInfo outer testComponent "parent" []
  entries ← collected
  map entryFields entries `shouldBe`
    [ fields [("service", "engine"), ("scope", "inner")]
    , fields [("service", "engine"), ("scope", "event")]
    , fields [("service", "engine"), ("scope", "outer")]
    ]
  map entryBreadcrumbs entries `shouldBe`
    [ ["startup", "worker"]
    , ["startup", "worker"]
    , ["startup"]
    ]
  where
    fields ∷ [(Text, Text)] → Map Text Text
    fields = Map.fromList

testConcurrentContext ∷ IO ()
testConcurrentContext = do
  (sink, collected) ← newCollector
  -- Real thread identities, so the two workers must report different ones.
  let root = withFields [("service", "engine")] (mkLogger defaultLogFilter sink)
  startOne ← newEmptyMVar
  startTwo ← newEmptyMVar
  doneOne ← newEmptyMVar
  doneTwo ← newEmptyMVar
  let worker name start done = void . forkIO $ do
        takeMVar start
        identity ← myThreadId
        logInfo (withFields [("worker", name)] root) testComponent "tick" []
        putMVar done (Text.pack (show identity))
  worker "one" startOne (doneOne ∷ MVar Text)
  worker "two" startTwo (doneTwo ∷ MVar Text)
  putMVar startOne ()
  putMVar startTwo ()
  threadOne ← takeMVar doneOne
  threadTwo ← takeMVar doneTwo
  threadOne `shouldNotBe` threadTwo
  entries ← collected
  map entryMessage entries `shouldBe` ["tick", "tick"]
  let observed name = [(entryFields entry, entryThread entry)
                      | entry ← entries
                      , Map.lookup "worker" (entryFields entry) == Just name]
  observed "one" `shouldBe`
    [(Map.fromList [("service", "engine"), ("worker", "one")], threadOne)]
  observed "two" `shouldBe`
    [(Map.fromList [("service", "engine"), ("worker", "two")], threadTwo)]

-- Source attribution ---------------------------------------------------------

-- | A wrapper declaring the call-stack constraint. The entry it emits must be
-- attributed to this function's own caller, which it returns for comparison.
logThroughWrapper ∷ HasCallStack ⇒ Logger → IO (Maybe SourceLocation)
logThroughWrapper logger = do
  logInfo logger testComponent "through wrapper" []
  pure (outermostSite callStack)

-- | The contract's attribution rule, computed independently of the logger.
outermostSite ∷ CallStack → Maybe SourceLocation
outermostSite stack = case reverse (getCallStack stack) of
  [] → Nothing
  ((name, location) : _) → Just SourceLocation
    { sourceFile = Text.pack (srcLocFile location)
    , sourceLine = srcLocStartLine location
    , sourceFunction = Text.pack name
    }

testSourceThroughWrapper ∷ IO ()
testSourceThroughWrapper = do
  (sink, collected) ← newCollector
  let logger = mkLoggerWith defaultLogFilter fixedMetadata sink
  expected ← logThroughWrapper logger
  expected `shouldSatisfy` (/= Nothing)
  entries ← collected
  -- The outer frame, not the `logInfo` call inside the wrapper.
  map (fmap sourceFunction . entrySource) entries `shouldBe` [Just "logThroughWrapper"]
  map entrySource entries `shouldBe` [expected]

testSourceDisabled ∷ IO ()
testSourceDisabled = do
  (sink, collected) ← newCollector
  let logger = mkLoggerWith defaultLogFilter { filterSource = False } fixedMetadata sink
  void (logThroughWrapper logger)
  entries ← collected
  map entrySource entries `shouldBe` [Nothing]

-- Runtime --------------------------------------------------------------------

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
