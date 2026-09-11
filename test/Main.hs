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
import System.Directory (getFileSize)
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
import System.Process (createPipe)
import System.Timeout (timeout)
import Test.Hspec
  ( anyIOException
  , describe
  , expectationFailure
  , hspec
  , it
  , shouldBe
  , shouldNotBe
  , shouldReturn
  , shouldSatisfy
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
