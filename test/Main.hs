module Main (main) where

import Control.Concurrent (forkIO, killThread, myThreadId)
import Control.Concurrent.MVar
  ( MVar
  , modifyMVar
  , modifyMVar_
  , newEmptyMVar
  , newMVar
  , putMVar
  , readMVar
  , takeMVar
  )
import Control.Exception
  ( AsyncException (ThreadKilled)
  , ErrorCall (ErrorCall)
  , IOException
  , SomeAsyncException
  , SomeException
  , bracket
  , evaluate
  , fromException
  , throwIO
  , try
  )
import Control.Monad (forM, forM_, replicateM_, void, when)
import Data.Char (isDigit)
import Data.Either (isLeft)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe (isJust, mapMaybe)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.IO as TextIO
import Data.Time.Calendar (fromGregorian)
import Data.Time.Clock (UTCTime (UTCTime), picosecondsToDiffTime, secondsToDiffTime)
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
import System.Directory (findExecutable, getFileSize)
import System.Environment (getEnvironment)
import System.Exit (ExitCode (ExitSuccess))
import System.FilePath ((</>))
import System.IO
  ( BufferMode (BlockBuffering, LineBuffering)
  , Handle
  , IOMode (WriteMode)
  , hClose
  , hGetBuffering
  , hGetChar
  , hGetContents
  , hIsOpen
  , hPutStrLn
  , hSetBuffering
  , openFile
  )
import System.IO.Error (ioeGetErrorString)
import System.IO.Temp (withSystemTempDirectory)
import System.Process
  ( CreateProcess (env)
  , createPipe
  , proc
  , readCreateProcessWithExitCode
  )
import System.Timeout (timeout)
import qualified Test.Engine.Resources.Spec as Resources
import Test.Hspec
  ( Expectation
  , anyIOException
  , describe
  , expectationFailure
  , hspec
  , it
  , shouldBe
  , shouldContain
  , shouldNotBe
  , shouldNotContain
  , shouldReturn
  , shouldSatisfy
  , shouldStartWith
  , shouldThrow
  )
import Text.Read (readMaybe)

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
  describe "Record layout" $ do
    it "renders the fixed-metadata examples" testLayoutExamples
    it "omits absent segments and sorts fields by key" testLayoutSegments
    it "omits the thread segment when the option is off" testLayoutThreadOption
    it "quotes and escapes text that would disturb the layout" testLayoutEscaping
    it "passes non-ASCII text through unchanged" testLayoutNonAscii
    it "quotes and escapes the source filename" testLayoutSourceFilename
    it "renders empty text as a pair of quotes" testLayoutEmptyText
    it "keeps an unvalidated field key from disturbing the layout" testLayoutFieldKeys
    it "truncates the timestamp to three fractional digits" testLayoutTimestamp
  describe "Handle sink" $ do
    it "terminates each record itself" testHandleRecordTerminator
    it "keeps concurrent records intact and in per-producer order" testHandleConcurrentRecords
    it "flushes every entry by default, and on demand when it does not" testHandleFlushing
    it "leaves the borrowed handle open, writable, and unchanged" testHandleBorrowed
    it "serializes two independently constructed roots" testHandleSharedRoots
    it "propagates a write failure and releases its serialization state" testHandleWriteFailure
    it "propagates an interruption and releases its serialization state" testHandleInterruption
    it "propagates a flush failure and releases its serialization state" testHandleFlushFailure
  describe "Callback sink" $ do
    it "defaults to a no-op flush and runs a supplied one" testCallbackFlush
    it "propagates callback and flush failures without disabling the sink" testCallbackFailure
  describe "Worker reporting boundary" $ do
    it "emits the success diagnostic for completed work" testWorkerSuccess
    it "reports an ordinary failure once and ends the worker" testWorkerFailure
    it "propagates cancellation delivered to blocked work, unreported" testWorkerCancelled
    it "keeps the work's exception when its report fails" testWorkerReportingFailure
    it "propagates cancellation delivered while the report blocks" testWorkerCancelledWhileReporting
    it "propagates a failing success diagnostic" testWorkerSuccessDiagnosticFailure
  describe "runApplication" $ do
    it "orders events and returns the application result" testRuntime
    it "propagates failure without reporting completion" testRuntimeFailure
  describe "Configuration parsing" $ do
    it "accepts every level spelling and rejects the rest" testParseLevel
    it "parses exact per-component overrides" testParseOverrides
    it "rejects a malformed override list" testParseOverridesRejected
    it "parses the Debug selection and collapses repeats" testParseDebug
    it "rejects a malformed Debug selection" testParseDebugRejected
    it "quotes and escapes a rejected value in its message" testParseEscaping
  describe "Startup configuration" $ do
    it "keeps every default when no variable is present" testResolveDefaults
    it "assembles the filter from all three variables" testResolveAll
    it "names the variable an invalid value came from" testResolveInvalid
    it "leaves the master and source switches programmatic" testResolveProgrammatic
    it "consults each variable exactly once and nothing afterwards" testResolveOnce
  describe "Console startup" $ do
    it "emits the smoke records under the default configuration" testConsoleDefault
    it "applies a threshold and an exact override to the smoke path" testConsoleThreshold
    it "fails before any entry for each invalid variable" testConsoleInvalid
    it "keeps a forged value from splitting the diagnostic" testConsoleForgedValue
    it "keeps help visible and validates configuration on that path" testConsoleHelp
  Resources.spec

-- Fixtures -------------------------------------------------------------------

testComponent ∷ Component
testComponent = unsafeComponent "test"

gpuComponent ∷ Component
gpuComponent = unsafeComponent "gpu.vulkan"

gameComponent ∷ Component
gameComponent = unsafeComponent "game.world"

luaComponent ∷ Component
luaComponent = unsafeComponent "lua"

fixedTime ∷ UTCTime
fixedTime = UTCTime (fromGregorian 2026 9 10) (secondsToDiffTime 43200)

-- | The layout shows the numeric GHC thread identity, so a fixture supplies a
-- number rather than a @Show@ spelling.
fixedThread ∷ Text
fixedThread = "3"

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
  pure (callbackSink sink, reverse <$> readMVar collected)

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
  let logger = mkLoggerWith defaultLogFilter fixedMetadata
        (callbackSink (\_ → ioError (userError "sink unavailable")))
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
        -- The same numeric identity 'systemMetadata' reports, derived here
        -- independently of the logger.
        putMVar done (Text.dropWhile (not . isDigit) (Text.pack (show identity)))
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

-- Record layout ---------------------------------------------------------------

-- | The issue's fixed metadata: 2026-09-10T12:34:56 plus a millisecond offset.
exampleTime ∷ Integer → UTCTime
exampleTime milliseconds = UTCTime (fromGregorian 2026 9 10) (picosecondsToDiffTime picoseconds)
  where
    picoseconds = (((12 * 3600 + 34 * 60 + 56) * 1000) + milliseconds) * 1000000000

-- | An entry with every optional segment absent, for a test to add one to.
plainEntry ∷ LogEntry
plainEntry = LogEntry
  { entryLevel = Info
  , entryComponent = testComponent
  , entryMessage = "plain"
  , entryFields = Map.empty
  , entryBreadcrumbs = []
  , entryTime = exampleTime 0
  , entryThread = fixedThread
  , entrySource = Nothing
  }

rendered ∷ LogEntry → Text
rendered = formatEntry defaultFormatOptions

testLayoutExamples ∷ IO ()
testLayoutExamples = do
  rendered plainEntry
    { entryComponent = unsafeComponent "runtime"
    , entryMessage = "Starting hetoimasia"
    , entryTime = exampleTime 789
    }
    `shouldBe` "2026-09-10T12:34:56.789Z INFO runtime thread=3 msg=\"Starting hetoimasia\""
  rendered plainEntry
    { entryLevel = Warning
    , entryComponent = gpuComponent
    , entryMessage = "Device lost\nretrying"
    , entryFields = Map.fromList [("device", "Radeon RX"), ("attempt", "2")]
    , entryBreadcrumbs = ["runtime", "gpu"]
    , entryTime = exampleTime 790
    , entryThread = "7"
    , entrySource = Just (SourceLocation "app/Main.hs" 42 "main")
    }
    `shouldBe`
      "2026-09-10T12:34:56.790Z WARN gpu.vulkan thread=7 src=app/Main.hs:42 \
      \crumbs=runtime>gpu msg=\"Device lost\\nretrying\" attempt=2 device=\"Radeon RX\""

testLayoutSegments ∷ IO ()
testLayoutSegments = do
  -- The pure formatter returns a record, never a terminated one.
  rendered plainEntry `shouldSatisfy` not . Text.isInfixOf "\n"
  -- Absent optional segments are omitted entirely, not left empty.
  rendered plainEntry `shouldBe` "2026-09-10T12:34:56.000Z INFO test thread=3 msg=plain"
  rendered plainEntry { entryBreadcrumbs = ["runtime"] }
    `shouldBe` "2026-09-10T12:34:56.000Z INFO test thread=3 crumbs=runtime msg=plain"
  rendered plainEntry { entrySource = Just (SourceLocation "app/Main.hs" 7 "main") }
    `shouldBe` "2026-09-10T12:34:56.000Z INFO test thread=3 src=app/Main.hs:7 msg=plain"
  -- Fields follow the message sorted by key, whatever order they were given.
  rendered plainEntry { entryFields = Map.fromList [("zulu", "3"), ("alpha", "1"), ("mike", "2")] }
    `shouldBe` "2026-09-10T12:34:56.000Z INFO test thread=3 msg=plain alpha=1 mike=2 zulu=3"
  -- Every level has its own spelling.
  map (\level → Text.words (rendered plainEntry { entryLevel = level }) !! 1)
    [Debug, Info, Warning, Error]
    `shouldBe` ["DEBUG", "INFO", "WARN", "ERROR"]

testLayoutThreadOption ∷ IO ()
testLayoutThreadOption =
  formatEntry defaultFormatOptions { formatThread = False } plainEntry
    { entryBreadcrumbs = ["runtime"] }
    `shouldBe` "2026-09-10T12:34:56.000Z INFO test crumbs=runtime msg=plain"

-- | Every character the quoting rules name, in one value.
awkward ∷ Text
awkward = "a\nb\rc\td\"e\\f=g>h i\SOHj"

-- | That value as the layout writes it, quotes included.
awkwardRendered ∷ Text
awkwardRendered = "\"a\\nb\\rc\\td\\\"e\\\\f=g>h i\\u0001j\""

testLayoutEscaping ∷ IO ()
testLayoutEscaping = do
  let line = rendered plainEntry
        { entryMessage = awkward
        , entryBreadcrumbs = [awkward]
        , entryFields = Map.fromList [("key", awkward)]
        }
  -- One record, whatever the payload held.
  line `shouldSatisfy` not . Text.isInfixOf "\n"
  line `shouldBe`
    "2026-09-10T12:34:56.000Z INFO test thread=3 crumbs=" <> awkwardRendered
      <> " msg=" <> awkwardRendered <> " key=" <> awkwardRendered
  -- Each reserved character alone is enough to quote a value; a bare value
  -- needs none of them.
  forM_ ["\"", "\\", "=", ">", " ", "\n", "\r", "\t", "\SOH", "\DEL"] $ \reserved →
    rendered plainEntry { entryMessage = "x" <> reserved <> "y" }
      `shouldSatisfy` Text.isInfixOf " msg=\""
  rendered plainEntry { entryMessage = "no-reserved.characters/here:1" }
    `shouldSatisfy` Text.isInfixOf " msg=no-reserved.characters/here:1"
  -- A breadcrumb holding the separator is quoted, so the join stays readable.
  rendered plainEntry { entryBreadcrumbs = ["a>b", "c"] }
    `shouldSatisfy` Text.isInfixOf " crumbs=\"a>b\">c "
  -- An ordinary key is bare, as every example shows.
  rendered plainEntry { entryFields = Map.fromList [("odd.key-1", "v")] }
    `shouldSatisfy` Text.isInfixOf " odd.key-1=v"

testLayoutNonAscii ∷ IO ()
testLayoutNonAscii = do
  -- Printable non-ASCII needs no quoting and no escape.
  rendered plainEntry { entryMessage = "Ωμ±é日本" }
    `shouldBe` "2026-09-10T12:34:56.000Z INFO test thread=3 msg=Ωμ±é日本"
  -- Quoted for the space it also holds, but otherwise unchanged.
  rendered plainEntry { entryFields = Map.fromList [("device", "Radeon Ωé")] }
    `shouldSatisfy` Text.isInfixOf " device=\"Radeon Ωé\""

testLayoutSourceFilename ∷ IO ()
testLayoutSourceFilename = do
  -- An ordinary path stays bare, exactly as the examples show.
  rendered plainEntry { entrySource = Just (SourceLocation "app/Main.hs" 42 "main") }
    `shouldSatisfy` Text.isInfixOf " src=app/Main.hs:42 "
  -- A filename is text like any other, so it cannot break the layout.
  rendered plainEntry { entrySource = Just (SourceLocation "src/My File.hs" 12 "f") }
    `shouldSatisfy` Text.isInfixOf " src=\"src/My File.hs\":12 "
  rendered plainEntry { entrySource = Just (SourceLocation "src/Qu\"ote.hs" 3 "f") }
    `shouldSatisfy` Text.isInfixOf " src=\"src/Qu\\\"ote.hs\":3 "
  let broken = rendered plainEntry { entrySource = Just (SourceLocation "src/Bad\nName.hs" 7 "f") }
  broken `shouldSatisfy` Text.isInfixOf " src=\"src/Bad\\nName.hs\":7 "
  broken `shouldSatisfy` not . Text.isInfixOf "\n"

testLayoutEmptyText ∷ IO ()
testLayoutEmptyText = do
  rendered plainEntry
    { entryMessage = ""
    , entryBreadcrumbs = ["", "gpu"]
    , entryFields = Map.fromList [("key", "")]
    }
    `shouldBe` "2026-09-10T12:34:56.000Z INFO test thread=3 crumbs=\"\">gpu msg=\"\" key=\"\""

-- | Field keys are raw 'Text' from the caller, unlike the validated component
-- name beside them, so the layout rule has to cover them too.
testLayoutFieldKeys ∷ IO ()
testLayoutFieldKeys = do
  let withKey key = rendered plainEntry { entryFields = Map.fromList [(key, "v")] }
  -- A key that would split the record is quoted and escaped instead.
  withKey "a\nb" `shouldBe` "2026-09-10T12:34:56.000Z INFO test thread=3 msg=plain \"a\\nb\"=v"
  withKey "a\nb" `shouldSatisfy` not . Text.isInfixOf "\n"
  -- So is one that would forge a segment, or an empty one.
  withKey "a b" `shouldSatisfy` Text.isInfixOf " \"a b\"=v"
  withKey "a=b" `shouldSatisfy` Text.isInfixOf " \"a=b\"=v"
  withKey "a>b" `shouldSatisfy` Text.isInfixOf " \"a>b\"=v"
  withKey "a\"b" `shouldSatisfy` Text.isInfixOf " \"a\\\"b\"=v"
  withKey "a\\b" `shouldSatisfy` Text.isInfixOf " \"a\\\\b\"=v"
  withKey "a\tb" `shouldSatisfy` Text.isInfixOf " \"a\\tb\"=v"
  withKey "a\SOHb" `shouldSatisfy` Text.isInfixOf " \"a\\u0001b\"=v"
  withKey "" `shouldSatisfy` Text.isInfixOf " \"\"=v"
  -- Keys still sort by their own text, whatever rendering they need.
  rendered plainEntry { entryFields = Map.fromList [("b key", "2"), ("a", "1"), ("c", "3")] }
    `shouldBe` "2026-09-10T12:34:56.000Z INFO test thread=3 msg=plain a=1 \"b key\"=2 c=3"

testLayoutTimestamp ∷ IO ()
testLayoutTimestamp = do
  let stamped time = Text.takeWhile (/= ' ') (rendered plainEntry { entryTime = time })
      atPicoseconds picoseconds =
        UTCTime (fromGregorian 2026 9 10) (picosecondsToDiffTime picoseconds)
  -- Always three digits, zero-padded.
  stamped (exampleTime 0) `shouldBe` "2026-09-10T12:34:56.000Z"
  stamped (exampleTime 7) `shouldBe` "2026-09-10T12:34:56.007Z"
  stamped (exampleTime 70) `shouldBe` "2026-09-10T12:34:56.070Z"
  -- Finer precision is truncated, never rounded up into a digit shown.
  stamped (atPicoseconds 999999999999) `shouldBe` "2026-09-10T00:00:00.999Z"
  stamped (atPicoseconds 1) `shouldBe` "2026-09-10T00:00:00.000Z"
  stamped (atPicoseconds 789999999999) `shouldBe` "2026-09-10T00:00:00.789Z"

-- Sink fixtures ---------------------------------------------------------------

-- | Long enough to bound a stuck test, never long enough to matter otherwise.
boundMicroseconds ∷ Int
boundMicroseconds = 10000000

-- | A call that must return rather than wait on serialization state a failed
-- or interrupted write should have released. Timing out is a test failure, not
-- an exception the assertion under it could mistake for the expected one.
bounded ∷ IO a → IO a
bounded action =
  timeout boundMicroseconds action
    >>= maybe (throwIO (ErrorCall "a logging call never returned")) pure

-- | A temporary log file opened for writing, with the caller's own buffering
-- established before the sink exists. The handle is the caller's throughout: a
-- test may close it itself to break the sink deliberately.
withLogHandle ∷ BufferMode → (FilePath → Handle → IO a) → IO a
withLogHandle buffering act =
  withSystemTempDirectory "hetoimasia-log" $ \directory → do
    let path = directory </> "records.log"
    bracket (openFile path WriteMode) closeIfOpen $ \handle → do
      hSetBuffering handle buffering
      act path handle
  where
    closeIfOpen handle = hIsOpen handle >>= \open → when open (hClose handle)

recordedLines ∷ FilePath → IO [Text]
recordedLines path = Text.lines <$> TextIO.readFile path

-- | The layout, checked structurally: a fragment of one interleaved write does
-- not parse, so this is what "every line is a whole record" means here.
parseRecord ∷ Text → Maybe (Text, Int)
parseRecord line = case Text.splitOn " " line of
  (time : level : component : thread : rest)
    | Text.length time == 24
    , Text.index time 10 == 'T'
    , Text.last time == 'Z'
    , level `elem` ["DEBUG", "INFO", "WARN", "ERROR"]
    , component == "test"
    , Just identity ← Text.stripPrefix "thread=" thread
    , Text.all isDigit identity
    , not (Text.null identity)
    , ["crumbs=worker"] == filter (Text.isPrefixOf "crumbs=") rest
    , ["msg=tick"] == filter (Text.isPrefixOf "msg=") rest
    , [worker] ← mapMaybe (Text.stripPrefix "worker=") rest
    , [number] ← mapMaybe (Text.stripPrefix "seq=") rest
    , Just index ← readMaybe (Text.unpack number)
    → Just (worker, index)
  _ → Nothing

-- Handle sink -----------------------------------------------------------------

testHandleRecordTerminator ∷ IO ()
testHandleRecordTerminator = withLogHandle LineBuffering $ \path handle → do
  sink ← newHandleSink handle
  let logger = mkLoggerWith defaultLogFilter { filterSource = False } fixedMetadata sink
  logInfo logger testComponent "terminated" []
  hClose handle
  -- The formatter returns no newline, so the record terminator is the sink's.
  TextIO.readFile path
    `shouldReturn` "2026-09-10T12:00:00.000Z INFO test thread=3 msg=terminated\n"

testHandleConcurrentRecords ∷ IO ()
testHandleConcurrentRecords = withLogHandle (BlockBuffering (Just 4096)) $ \path handle → do
  sink ← newHandleSink handle
  -- Real thread identities, derived loggers, one shared sink.
  let root = mkLogger defaultLogFilter sink
      names = ["one", "two", "three", "four"]
      perWorker = 25 ∷ Int
  gate ← newEmptyMVar
  dones ← forM names $ \name → do
    done ← newEmptyMVar
    void . forkIO $ do
      -- Released together, joined by completion; no sleep decides anything.
      readMVar gate
      let worker = withBreadcrumb "worker" (withFields [("worker", name)] root)
      forM_ [1 .. perWorker] $ \index →
        logInfo worker testComponent "tick" [("seq", Text.pack (show index))]
      putMVar done ()
    pure (done ∷ MVar ())
  putMVar gate ()
  forM_ dones takeMVar
  flushLogger root
  hClose handle
  recorded ← recordedLines path
  length recorded `shouldBe` length names * perWorker
  forM_ recorded $ \line → (line, parseRecord line) `shouldSatisfy` isJust . snd
  let parsed = mapMaybe parseRecord recorded
  -- Each producer's own order survives; between producers nothing is promised.
  forM_ names $ \name →
    [index | (worker, index) ← parsed, worker == name] `shouldBe` [1 .. perWorker]

-- | Whether anything has reached the file yet. A handle open for writing holds
-- GHC's file lock, so the size is what an unrelated observer can see while the
-- caller still owns the handle.
onDisk ∷ FilePath → IO Bool
onDisk path = (> 0) <$> getFileSize path

testHandleFlushing ∷ IO ()
testHandleFlushing = do
  -- The caller chose block buffering before the sink existed, and one record
  -- is far smaller than that buffer, so only a flush can reveal it.
  let quiet = defaultLogFilter { filterSource = False }
  withLogHandle (BlockBuffering (Just 65536)) $ \path handle → do
    buffering ← hGetBuffering handle
    sink ← newHandleSink handle
    -- Constructing the sink left the caller's buffering alone.
    hGetBuffering handle `shouldReturn` buffering
    let logger = mkLoggerWith quiet fixedMetadata sink
    logInfo logger testComponent "immediate" []
    onDisk path `shouldReturn` True
    hClose handle
    recordedLines path
      `shouldReturn` ["2026-09-10T12:00:00.000Z INFO test thread=3 msg=immediate"]
  withLogHandle (BlockBuffering (Just 65536)) $ \path handle → do
    sink ← newHandleSinkWith defaultFormatOptions { formatFlush = False } handle
    let logger = mkLoggerWith quiet fixedMetadata sink
        derived = withBreadcrumb "worker" logger
    logInfo logger testComponent "deferred" []
    onDisk path `shouldReturn` False
    -- Derived loggers share the root's sink, so either one flushes it.
    flushLogger derived
    onDisk path `shouldReturn` True
    hClose handle
    recordedLines path
      `shouldReturn` ["2026-09-10T12:00:00.000Z INFO test thread=3 msg=deferred"]

testHandleBorrowed ∷ IO ()
testHandleBorrowed = withLogHandle LineBuffering $ \path handle → do
  buffering ← hGetBuffering handle
  sink ← newHandleSink handle
  let logger = mkLoggerWith defaultLogFilter { filterSource = False } fixedMetadata sink
  logInfo logger testComponent "borrowed" []
  flushLogger logger
  -- Discarding every logger over the sink closes and changes nothing.
  hIsOpen handle `shouldReturn` True
  hGetBuffering handle `shouldReturn` buffering
  hPutStrLn handle "the caller still owns this handle"
  hClose handle
  recordedLines path `shouldReturn`
    [ "2026-09-10T12:00:00.000Z INFO test thread=3 msg=borrowed"
    , "the caller still owns this handle"
    ]

testHandleSharedRoots ∷ IO ()
testHandleSharedRoots = withLogHandle LineBuffering $ \path handle → do
  -- Two roots over one handle share one sink: that is the supported way.
  sink ← newHandleSink handle
  let quiet = defaultLogFilter { filterSource = False }
      first = mkLoggerWith quiet fixedMetadata sink
      second = mkLoggerWith quiet { filterGlobalLevel = Warning } fixedMetadata sink
  logInfo first testComponent "from the first root" []
  logInfo second testComponent "suppressed by the second root's own filter" []
  logWarning second gpuComponent "from the second root" []
  flushLogger second
  hClose handle
  recordedLines path `shouldReturn`
    [ "2026-09-10T12:00:00.000Z INFO test thread=3 msg=\"from the first root\""
    , "2026-09-10T12:00:00.000Z WARN gpu.vulkan thread=3 msg=\"from the second root\""
    ]

testHandleWriteFailure ∷ IO ()
testHandleWriteFailure = withLogHandle LineBuffering $ \_ handle → do
  sink ← newHandleSink handle
  let root = mkLoggerWith defaultLogFilter fixedMetadata sink
      derived = withBreadcrumb "worker" root
  hClose handle
  logInfo root testComponent "first" [] `shouldThrow` anyIOException
  -- The failed write gave its serialization state back, so a sharing logger
  -- reports the handle's own failure instead of waiting for it forever.
  bounded (logInfo derived testComponent "second" []) `shouldThrow` anyIOException
  bounded (logInfo root testComponent "third" []) `shouldThrow` anyIOException

testHandleFlushFailure ∷ IO ()
testHandleFlushFailure = withLogHandle LineBuffering $ \_ handle → do
  sink ← newHandleSinkWith defaultFormatOptions { formatFlush = False } handle
  let root = mkLoggerWith defaultLogFilter fixedMetadata sink
      derived = withBreadcrumb "worker" root
  hClose handle
  bounded (flushLogger root) `shouldThrow` anyIOException
  bounded (flushLogger derived) `shouldThrow` anyIOException
  bounded (logInfo derived testComponent "after" []) `shouldThrow` anyIOException

-- | A record far larger than a pipe can absorb, so the writer is still inside
-- the sink — holding its serialization state — when the reader sees the first
-- chunk. That is the coordination; the timeouts only bound a stuck test.
testHandleInterruption ∷ IO ()
testHandleInterruption = do
  (readEnd, writeEnd) ← createPipe
  hSetBuffering writeEnd (BlockBuffering (Just 65536))
  sink ← newHandleSinkWith defaultFormatOptions { formatFlush = False } writeEnd
  let root = mkLoggerWith defaultLogFilter { filterSource = False } fixedMetadata sink
      blocked = withFields [("producer", "blocked")] root
      other = withFields [("producer", "other")] root
  outcome ← newEmptyMVar
  writer ← forkIO $ do
    result ← try (logInfo blocked testComponent (Text.replicate 200000 "abcde") [])
    putMVar outcome (result ∷ Either SomeException ())
  -- Nothing drains the pipe yet, so this chunk can only come from a writer
  -- that is still far from finished with a record the pipe cannot hold.
  bounded (replicateM_ 4096 (void (hGetChar readEnd)))
  bounded (killThread writer)
  interrupted ← bounded (takeMVar outcome)
  case interrupted of
    Right () → expectationFailure "the interrupted write reported success"
    Left failure → (fromException failure ∷ Maybe AsyncException) `shouldBe` Just ThreadKilled
  -- Draining again from here, so the only thing a sharing logger could wait on
  -- is serialization state the interruption should have released.
  drainer ← forkIO . void $
    (try (hGetContents readEnd >>= void . evaluate . length) ∷ IO (Either SomeException ()))
  proceeded ← timeout boundMicroseconds (try (logInfo other testComponent "after" []))
  -- The caller's handle still holds whatever the interrupted write left
  -- buffered, so it is closed while the drainer is still reading.
  void (bounded (try (hClose writeEnd) ∷ IO (Either SomeException ())))
  killThread drainer
  hClose readEnd
  -- Completing or reporting the handle's own failure are both fine; waiting
  -- on serialization state the interruption should have released is not.
  case proceeded ∷ Maybe (Either SomeException ()) of
    Nothing → expectationFailure "a sharing logger never returned after the interruption"
    Just _ → pure ()

-- Callback sink ---------------------------------------------------------------

testCallbackFlush ∷ IO ()
testCallbackFlush = do
  -- The default flush is a no-op: it neither fails nor reaches the callback.
  (sink, collected) ← newCollector
  flushLogger (mkLoggerWith defaultLogFilter fixedMetadata sink)
  collected `shouldReturn` []
  -- A supplied flush action runs on explicit flush, and only then.
  flushes ← newMVar (0 ∷ Int)
  let counting = callbackSinkWith (\_ → pure ()) (modifyMVar_ flushes (pure . (+ 1)))
      logger = mkLoggerWith defaultLogFilter fixedMetadata counting
  logInfo logger testComponent "entry" []
  readMVar flushes `shouldReturn` 0
  flushLogger logger
  readMVar flushes `shouldReturn` 1
  flushLogger (withBreadcrumb "worker" logger)
  readMVar flushes `shouldReturn` 2

testCallbackFailure ∷ IO ()
testCallbackFailure = do
  failures ← newMVar (0 ∷ Int)
  seen ← newMVar ([] ∷ [Text])
  -- Fails on its first entry only, so a later call shows the sink still works.
  let callback entry = do
        attempt ← modifyMVar failures (\count → pure (count + 1, count + 1))
        if attempt == 1
          then ioError (userError "callback unavailable")
          else modifyMVar_ seen (pure . (entryMessage entry :))
      sink = callbackSinkWith callback (ioError (userError "flush unavailable"))
      root = mkLoggerWith defaultLogFilter fixedMetadata sink
      derived = withBreadcrumb "worker" root
  logInfo root testComponent "first" [] `shouldThrow`
    ((== "callback unavailable") . ioeGetErrorString)
  -- A sharing logger proceeds after the failure, and Error is a severity
  -- rather than an exception.
  logInfo derived testComponent "second" []
  logError derived testComponent "third" []
  (reverse <$> readMVar seen) `shouldReturn` ["second", "third"]
  -- A failing flush propagates the same way.
  flushLogger derived `shouldThrow` ((== "flush unavailable") . ioeGetErrorString)

-- Worker reporting boundary ---------------------------------------------------

-- The worker example from the "Usage" section of docs/logging.md, mirrored here
-- verbatim so the guide and the behaviour these cases assert cannot drift.

uploadComponent ∷ Component
uploadComponent = unsafeComponent "upload"

-- The terminal reporting boundary for one uploader.
uploaderWorker ∷ Logger → Int → (Logger → IO Int) → IO ()
uploaderWorker logger worker work = do
  let scoped = withFields [("worker", Text.pack (show worker))] logger
  outcome ← try (work scoped)
  case outcome of
    Right uploaded →
      logInfo scoped uploadComponent "Uploads drained"
        [("uploaded", Text.pack (show uploaded))]
    Left failure
      | isCancellation failure → throwIO failure
      | otherwise → reportAbandoned scoped failure

-- One reporting attempt, and never a second one through the same sink.
reportAbandoned ∷ Logger → SomeException → IO ()
reportAbandoned scoped failure = do
  reported ← try (logError scoped uploadComponent "Uploads abandoned"
                    [("reason", Text.pack (show failure))])
  case reported of
    Right () → pure ()
    Left reportingFailure
      | isCancellation reportingFailure → throwIO reportingFailure
      | otherwise → throwIO failure

-- Anything thrown as asynchronous is cancellation, so ThreadKilled,
-- UserInterrupt, and the exception a timeout delivers are classified alike.
isCancellation ∷ SomeException → Bool
isCancellation failure = isJust (fromException failure ∷ Maybe SomeAsyncException)

-- | The work's own failure, distinguishable from any sink failure by both its
-- type and its payload.
uploadFailure ∷ ErrorCall
uploadFailure = ErrorCall "upload queue exploded"

-- | The example body on its own thread, with its outcome published rather than
-- left to escape into the runner.
workerOutcome ∷ Logger → (Logger → IO Int) → IO (Either SomeException ())
workerOutcome logger work = do
  outcome ← newEmptyMVar
  void . forkIO $ try (uploaderWorker logger 7 work) >>= putMVar outcome
  bounded (takeMVar outcome)

-- | The same, killed once the gate proves the worker has parked at an
-- interruptible point. The gate is the coordination: nothing here sleeps.
cancelledWorkerOutcome
  ∷ Logger → MVar () → (Logger → IO Int) → IO (Either SomeException ())
cancelledWorkerOutcome logger entered work = do
  outcome ← newEmptyMVar
  worker ← forkIO $ try (uploaderWorker logger 7 work) >>= putMVar outcome
  bounded (takeMVar entered)
  bounded (killThread worker)
  bounded (takeMVar outcome)

-- | Signals that it has arrived, then blocks on an `MVar` the test holds and
-- never fills. That retained reference is what makes this an interruptible
-- block rather than a deadlock the runtime would report as an ordinary failure.
blockedAt ∷ MVar () → MVar () → IO a
blockedAt entered held = do
  putMVar entered ()
  takeMVar held
  throwIO (ErrorCall "a blocked action was released")

-- | The worker ended normally; anything that escaped is the failure.
completed ∷ Either SomeException () → Expectation
completed (Right ()) = pure ()
completed (Left failure) =
  expectationFailure ("the worker failed with " <> show failure)

-- | The cancellation escaped as itself, rather than as success or as some
-- earlier exception the boundary had in hand.
cancelled ∷ Either SomeException () → Expectation
cancelled (Right ()) = expectationFailure "the cancelled worker reported success"
cancelled (Left failure) =
  (fromException failure ∷ Maybe AsyncException) `shouldBe` Just ThreadKilled

-- | The one field a reporting case cares about, with its count.
reasonFields ∷ [LogEntry] → [Text]
reasonFields = mapMaybe (Map.lookup "reason" . entryFields)

testWorkerSuccess ∷ IO ()
testWorkerSuccess = do
  (sink, collected) ← newCollector
  let logger = mkLoggerWith defaultLogFilter fixedMetadata sink
  workerOutcome logger (\_ → pure 12) >>= completed
  entries ← collected
  summaries entries `shouldBe` [(Info, "upload", "Uploads drained")]
  map (Map.lookup "uploaded" . entryFields) entries `shouldBe` [Just "12"]
  -- The worker's derived field reaches the record without the caller's logger
  -- having acquired it.
  map (Map.lookup "worker" . entryFields) entries `shouldBe` [Just "7"]

testWorkerFailure ∷ IO ()
testWorkerFailure = do
  (sink, collected) ← newCollector
  let logger = mkLoggerWith defaultLogFilter fixedMetadata sink
  -- An ordinary failure ends at the boundary: one Error record, and the worker
  -- returns rather than rethrowing to a caller that no longer exists.
  workerOutcome logger (\_ → throwIO uploadFailure) >>= completed
  entries ← collected
  summaries entries `shouldBe` [(Error, "upload", "Uploads abandoned")]
  case reasonFields entries of
    [reason] → Text.unpack reason `shouldContain` "upload queue exploded"
    other → expectationFailure ("unexpected reason fields: " <> show other)

testWorkerCancelled ∷ IO ()
testWorkerCancelled = do
  (sink, collected) ← newCollector
  let logger = mkLoggerWith defaultLogFilter fixedMetadata sink
  entered ← newEmptyMVar
  held ← newEmptyMVar
  -- Delivered to blocked work, so this is an actual asynchronous exception
  -- rather than a value the test threw synchronously to stand in for one.
  cancelledWorkerOutcome logger entered (\_ → blockedAt entered held) >>= cancelled
  -- Cancellation is reported nowhere: no Error, and no Info either.
  collected `shouldReturn` []

testWorkerReportingFailure ∷ IO ()
testWorkerReportingFailure = do
  attempts ← newMVar (0 ∷ Int)
  let sink = callbackSink $ \_ → do
        modifyMVar_ attempts (pure . (+ 1))
        ioError (userError "sink unavailable")
      logger = mkLoggerWith defaultLogFilter fixedMetadata sink
  outcome ← workerOutcome logger (\_ → throwIO uploadFailure)
  case outcome of
    Right () → expectationFailure "the work failure did not escape"
    Left failure → do
      -- The work's exception, with its payload, and not the sink's.
      (fromException failure ∷ Maybe ErrorCall) `shouldBe` Just uploadFailure
      (fromException failure ∷ Maybe IOException) `shouldBe` Nothing
  -- Exactly one attempt: a failed report is never reported back through the
  -- sink that just failed.
  readMVar attempts `shouldReturn` 1

testWorkerCancelledWhileReporting ∷ IO ()
testWorkerCancelledWhileReporting = do
  entered ← newEmptyMVar
  held ← newEmptyMVar
  let logger = mkLoggerWith defaultLogFilter fixedMetadata
        (callbackSink (\_ → blockedAt entered held))
  -- The work fails synchronously first, so a boundary that let that earlier
  -- exception win would surface ErrorCall here instead of ThreadKilled.
  cancelledWorkerOutcome logger entered (\_ → throwIO uploadFailure) >>= cancelled

testWorkerSuccessDiagnosticFailure ∷ IO ()
testWorkerSuccessDiagnosticFailure = do
  let logger = mkLoggerWith defaultLogFilter fixedMetadata
        (callbackSink (\_ → ioError (userError "sink unavailable")))
  outcome ← workerOutcome logger (\_ → pure 12)
  case outcome of
    Right () →
      expectationFailure "the success diagnostic's sink failure did not propagate"
    Left failure →
      (ioeGetErrorString <$> (fromException failure ∷ Maybe IOException))
        `shouldBe` Just "sink unavailable"

-- Configuration parsing -------------------------------------------------------

-- | The variable names the console application chooses, used by both the
-- injected-lookup assembly cases and the child-process startup cases so the two
-- describe one contract.
consoleVariables ∷ LogVariables
consoleVariables = LogVariables
  { variableGlobalLevel = "HETOIMASIA_LOG_LEVEL"
  , variableComponentLevels = "HETOIMASIA_LOG_LEVELS"
  , variableDebug = "HETOIMASIA_DEBUG"
  }

-- | A rejection must carry the text that identifies what was wrong, because
-- that message is the whole startup diagnostic.
rejects ∷ Show a ⇒ (Text → Either Text a) → (Text, Text) → Expectation
rejects parse (value, expected) = case parse value of
  Right accepted →
    expectationFailure ("accepted " <> show value <> " as " <> show accepted)
  Left reason → Text.unpack reason `shouldContain` Text.unpack expected

testParseLevel ∷ IO ()
testParseLevel = do
  forM_ accepted $ \(value, level) → parseLogLevel value `shouldBe` Right level
  forM_ rejected (rejects parseLogLevel)
  where
    -- Spellings are case-insensitive and surrounding whitespace is trimmed;
    -- "warn" and "warning" are the same level.
    accepted =
      [ ("info", Info)
      , ("INFO", Info)
      , ("Warn", Warning)
      , ("warning", Warning)
      , ("error", Error)
      , ("debug", Debug)
      , (" info ", Info)
      ]
    -- An empty value is an error rather than the default.
    rejected = [("verbose", "verbose"), ("warnings", "warnings"), ("", "required")]

testParseOverrides ∷ IO ()
testParseOverrides = do
  parseComponentLevels "gpu.vulkan=warn,lua=info"
    `shouldBe` Right (Map.fromList [(gpuComponent, Warning), (luaComponent, Info)])
  -- Whitespace around an entry, a name, and a value is trimmed.
  parseComponentLevels " gpu.vulkan = warn "
    `shouldBe` Right (Map.fromList [(gpuComponent, Warning)])

testParseOverridesRejected ∷ IO ()
testParseOverridesRejected = forM_ rejected (rejects parseComponentLevels)
  where
    rejected =
      [ ("gpu.vulkan=warn,gpu.vulkan=info", "appears twice")
      , ("gpu.vulkan", "expected component=level")
      , ("Gpu.Vulkan=warn", "Gpu.Vulkan")
      , ("gpu vulkan=warn", "gpu vulkan")
      , ("gpu.vulkan=warn,", "an entry is empty")
      , ("lua=verbose", "expected debug, info")
      , ("", "required")
      ]

testParseDebug ∷ IO ()
testParseDebug = do
  parseDebugSelection "none" `shouldBe` Right DebugNone
  parseDebugSelection "all" `shouldBe` Right DebugAll
  parseDebugSelection "gpu.vulkan,lua"
    `shouldBe` Right (DebugComponents (Set.fromList [gpuComponent, luaComponent]))
  -- A repeated component is one selection, not an error.
  parseDebugSelection "gpu.vulkan,gpu.vulkan"
    `shouldBe` Right (DebugComponents (Set.fromList [gpuComponent]))

testParseDebugRejected ∷ IO ()
testParseDebugRejected = forM_ rejected (rejects parseDebugSelection)
  where
    -- The selectors are exactly lowercase and never mix with component names.
    rejected =
      [ ("all,gpu.vulkan", "cannot be combined")
      , ("NONE", "lowercase")
      , ("All", "lowercase")
      , ("gpu.vulkan,", "an entry is empty")
      , ("", "required")
      ]

testParseEscaping ∷ IO ()
testParseEscaping = do
  -- A rejected value is quoted and escaped the way the record layout escapes
  -- text, so nothing a value carries can split the diagnostic or forge a line.
  forM_ rejections $ \(parse, value) → case parse value of
    Right accepted → expectationFailure ("accepted " <> show value <> ": " <> accepted)
    Left reason → do
      Text.unpack reason `shouldContain` "\"bad\\nforged\""
      Text.lines reason `shouldBe` [reason]
  where
    forged = "bad\nforged"
    -- Each parser reports through the same helper, including the component
    -- rejection an override list propagates.
    rejections =
      [ (fmap show . parseLogLevel, forged)
      , (fmap show . parseComponentLevels, forged <> "=warn")
      , (fmap show . parseDebugSelection, forged)
      , (fmap show . mkComponent, forged)
      ]

-- Startup configuration -------------------------------------------------------

-- | A lookup over a fixed table, with no environment behind it at all.
tableLookup ∷ [(Text, Text)] → Text → IO (Maybe Text)
tableLookup table name = pure (lookup name table)

-- | The resolved configuration, failing the example with the reason instead.
expectResolved ∷ Either Text LogFilter → IO LogFilter
expectResolved = either reject pure
  where
    reject reason = do
      expectationFailure ("startup rejected a valid configuration: " <> Text.unpack reason)
      -- Unreachable: 'expectationFailure' throws.
      pure defaultLogFilter

testResolveDefaults ∷ IO ()
testResolveDefaults =
  -- An absent variable keeps its default, so an empty environment resolves to
  -- exactly the default filter.
  resolveLogFilter consoleVariables (tableLookup []) defaultLogFilter
    `shouldReturn` Right defaultLogFilter

testResolveAll ∷ IO ()
testResolveAll = do
  resolved ← resolveLogFilter consoleVariables (tableLookup table) defaultLogFilter
  resolved `shouldBe` Right defaultLogFilter
    { filterGlobalLevel = Warning
    , filterComponentLevels = Map.fromList [(gpuComponent, Error), (gameComponent, Debug)]
    , filterDebug = DebugComponents (Set.fromList [gpuComponent])
    }
  where
    table =
      [ ("HETOIMASIA_LOG_LEVEL", "Warn")
      , ("HETOIMASIA_LOG_LEVELS", "gpu.vulkan=error, game.world=debug ")
      , ("HETOIMASIA_DEBUG", "gpu.vulkan")
      ]

testResolveInvalid ∷ IO ()
testResolveInvalid = forM_ invalid $ \(name, value) → do
  -- Each variable is invalid while the other two are absent, so only the one
  -- under test can be the variable the message names.
  resolved ← resolveLogFilter consoleVariables (tableLookup [(name, value)]) defaultLogFilter
  case resolved of
    Right accepted → expectationFailure ("startup accepted " <> show value <> ": " <> show accepted)
    Left reason → Text.unpack reason `shouldStartWith` (Text.unpack name <> ": ")
  where
    invalid =
      [ ("HETOIMASIA_LOG_LEVEL", "verbose")
      , ("HETOIMASIA_LOG_LEVELS", "gpu.vulkan=warn,gpu.vulkan=info")
      , ("HETOIMASIA_DEBUG", "All")
      ]

testResolveProgrammatic ∷ IO ()
testResolveProgrammatic = forM_ [False, True] $ \switch → do
  -- No variable controls the master or source switch: whatever the base
  -- configuration set, the resolved one keeps.
  let base = defaultLogFilter { filterEnabled = switch, filterSource = switch }
  configuration ←
    resolveLogFilter consoleVariables (tableLookup table) base >>= expectResolved
  filterEnabled configuration `shouldBe` switch
  filterSource configuration `shouldBe` switch
  filterGlobalLevel configuration `shouldBe` Error
  where
    table =
      [ ("HETOIMASIA_LOG_LEVEL", "error")
      , ("HETOIMASIA_LOG_LEVELS", "lua=info")
      , ("HETOIMASIA_DEBUG", "all")
      ]

testResolveOnce ∷ IO ()
testResolveOnce = do
  -- Acquisition consults each supported variable exactly once, in order, and
  -- consults nothing else.
  (valid, configuration) ← consult table
  valid `shouldBe` names
  -- Logging through the resolved filter reads no variable again: the filter is
  -- a value and the logger holds no lookup.
  (sink, collected) ← newCollector
  let logger = mkLoggerWith configuration fixedMetadata sink
  logInfo logger testComponent "after startup" []
  logDebug logger gpuComponent "detail" []
  (length <$> collected) `shouldReturn` 2
  consulted ← consult table
  fst consulted `shouldBe` names
  -- An invalid value does not short-circuit acquisition either: every lookup
  -- happens before any value is parsed.
  rejectedLookups ← newMVar ([] ∷ [Text])
  void $ resolveLogFilter consoleVariables (recording rejectedLookups broken) defaultLogFilter
  (reverse <$> readMVar rejectedLookups) `shouldReturn` names
  where
    names = ["HETOIMASIA_LOG_LEVEL", "HETOIMASIA_LOG_LEVELS", "HETOIMASIA_DEBUG"]
    table =
      [ ("HETOIMASIA_LOG_LEVEL", "info")
      , ("HETOIMASIA_LOG_LEVELS", "gpu.vulkan=debug")
      , ("HETOIMASIA_DEBUG", "gpu.vulkan")
      ]
    broken = [("HETOIMASIA_LOG_LEVEL", "verbose")]

    recording seen values name = do
      modifyMVar_ seen (pure . (name :))
      pure (lookup name values)

    consult values = do
      seen ← newMVar []
      configuration ←
        resolveLogFilter consoleVariables (recording seen values) defaultLogFilter
          >>= expectResolved
      (,) <$> (reverse <$> readMVar seen) <*> pure configuration

-- Console startup -------------------------------------------------------------

-- | The three variable names the console application reads, as the environment
-- spells them.
consoleVariableNames ∷ [String]
consoleVariableNames =
  map Text.unpack
    [ variableGlobalLevel consoleVariables
    , variableComponentLevels consoleVariables
    , variableDebug consoleVariables
    ]

-- | Run the built console executable with exactly the logging variables a case
-- asks for: the inherited environment is stripped of all three first, so an
-- inherited value can neither defeat a quiet run nor fail a default one. The
-- executable is reached through this suite's @build-tool-depends@ on it rather
-- than a guessed build path.
runConsole ∷ [(String, String)] → [String] → IO (ExitCode, String, String)
runConsole variables arguments = do
  found ← findExecutable "hetoimasia"
  case found of
    Nothing → fail "the hetoimasia executable is not on this test's search path"
    Just executable → do
      inherited ← getEnvironment
      let controlled =
            [ pair | pair@(name, _) ← inherited, name `notElem` consoleVariableNames ]
              <> variables
      readCreateProcessWithExitCode
        (proc executable arguments) { env = Just controlled }
        ""

-- | The component of each rendered record, which is its third segment. A line
-- that is not a record is kept whole so a failure shows it.
recordComponents ∷ String → [String]
recordComponents = map component . lines
  where
    component line = case words line of
      (_ : _ : name : _) → name
      _ → line

testConsoleDefault ∷ IO ()
testConsoleDefault = do
  (code, output, diagnostics) ← runConsole [] ["--smoke"]
  code `shouldBe` ExitSuccess
  -- Records are diagnostics on stderr; the smoke path writes no application
  -- output of its own.
  output `shouldBe` ""
  recordComponents diagnostics `shouldBe` ["runtime", "console", "runtime"]

testConsoleThreshold ∷ IO ()
testConsoleThreshold = do
  -- Only the variable under test is set, so this quiet run cannot be defeated
  -- by an inherited component override.
  (quiet, output, silent) ← runConsole [("HETOIMASIA_LOG_LEVEL", "warn")] ["--smoke"]
  quiet `shouldBe` ExitSuccess
  output `shouldBe` ""
  silent `shouldBe` ""
  -- An exact override silences one component while the other keeps the global
  -- default, which is the precedence the filter promises.
  (overridden, _, records) ←
    runConsole [("HETOIMASIA_LOG_LEVELS", "runtime=warn")] ["--smoke"]
  overridden `shouldBe` ExitSuccess
  recordComponents records `shouldBe` ["console"]

testConsoleInvalid ∷ IO ()
testConsoleInvalid = forM_ invalid $ \(name, value) → do
  (code, output, diagnostics) ← runConsole [(name, value)] ["--smoke"]
  code `shouldNotBe` ExitSuccess
  -- Exactly one line, naming the variable and the reason. Nothing else reached
  -- stderr, so startup failed before any entry was emitted, and the smoke
  -- action never ran.
  length (lines diagnostics) `shouldBe` 1
  diagnostics `shouldStartWith` (name <> ": ")
  diagnostics `shouldContain` value
  diagnostics `shouldNotContain` "Hello from Hetoimasia."
  output `shouldBe` ""
  where
    invalid =
      [ ("HETOIMASIA_LOG_LEVEL", "verbose")
      , ("HETOIMASIA_LOG_LEVELS", "gpu.vulkan=warn,gpu.vulkan=info")
      , ("HETOIMASIA_DEBUG", "All")
      ]

testConsoleForgedValue ∷ IO ()
testConsoleForgedValue = do
  -- An embedded newline in a value must not reach stderr as a second line: the
  -- startup contract is one line naming the variable and the reason.
  (code, output, diagnostics) ←
    runConsole [("HETOIMASIA_LOG_LEVEL", "bad\nforged")] ["--smoke"]
  code `shouldNotBe` ExitSuccess
  output `shouldBe` ""
  length (lines diagnostics) `shouldBe` 1
  diagnostics `shouldStartWith` "HETOIMASIA_LOG_LEVEL: "
  diagnostics `shouldContain` "\"bad\\nforged\""

testConsoleHelp ∷ IO ()
testConsoleHelp = do
  -- Help is ordinary application output, so a threshold that silences every
  -- record leaves it visible, and it names all three variables.
  (code, output, diagnostics) ← runConsole [("HETOIMASIA_LOG_LEVEL", "error")] ["--help"]
  code `shouldBe` ExitSuccess
  diagnostics `shouldBe` ""
  output `shouldContain` "Usage: hetoimasia"
  forM_ consoleVariableNames (shouldContain output)
  -- The help path resolves configuration first, so an invalid value fails it
  -- too, printing no help at all.
  (rejected, helpOutput, reason) ← runConsole [("HETOIMASIA_DEBUG", "NONE")] ["--help"]
  rejected `shouldNotBe` ExitSuccess
  helpOutput `shouldBe` ""
  reason `shouldStartWith` "HETOIMASIA_DEBUG: "
