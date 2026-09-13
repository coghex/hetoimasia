-- | Examples for the handle and callback sinks.
--
-- Concurrency is coordinated with pipes, gates, and 'MVar's; 'bounded' only
-- stops a call that has already hung, and never decides an assertion.
module Test.Engine.Logging.Sink (spec) where

import Control.Concurrent (forkIO, killThread)
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
  , SomeException
  , bracket
  , evaluate
  , fromException
  , try
  )
import Control.Monad (forM, forM_, replicateM_, void, when)
import Data.Char (isDigit)
import Data.Maybe (isJust, mapMaybe)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.IO as TextIO
import Hetoimasia.Foundation.Log
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
import Test.Engine.Logging.Support
  ( boundMicroseconds
  , bounded
  , fixedMetadata
  , gpuComponent
  , newCollector
  , testComponent
  )
import Test.Hspec
  ( Spec
  , anyIOException
  , describe
  , expectationFailure
  , it
  , shouldBe
  , shouldReturn
  , shouldSatisfy
  , shouldThrow
  )
import Text.Read (readMaybe)

spec ∷ Spec
spec = do
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
