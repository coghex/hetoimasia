-- | Examples for 'Hetoimasia.Runtime.AsyncLog', the optional bounded
-- asynchronous adapter over a borrowed synchronous sink.
--
-- Every example observes what an owner can see: what the borrowed sink was
-- asked to do and in which order, what it actually received, and the adapter's
-- own account of admission, loss, and the writer.
--
-- Concurrency is coordinated with 'MVar' latches and with the adapter's own
-- 'adapterStatusSTM', never with a sleep; 'bounded' only stops an example that
-- has already hung.
module Test.Runtime.AsyncLog (spec) where

import Control.Concurrent (ThreadId, forkIO, killThread, myThreadId)
import Control.Concurrent.MVar
  ( MVar
  , modifyMVar_
  , newEmptyMVar
  , newMVar
  , putMVar
  , readMVar
  , takeMVar
  , tryTakeMVar
  )
import Control.Concurrent.STM (atomically, check)
import Control.Exception
  ( AsyncException (ThreadKilled)
  , ErrorCall (ErrorCall)
  , SomeException
  , fromException
  , someExceptionContext
  , throwIO
  , try
  , uninterruptibleMask_
  )
import Control.Exception.Context (getExceptionAnnotations)
import Control.Monad (forM, forM_, replicateM_, void, when)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Text.Foreign (lengthWord8)
import Data.Time.Calendar (fromGregorian)
import Data.Time.Clock (UTCTime (UTCTime), secondsToDiffTime)
import Hetoimasia.Foundation.Log
  ( Component
  , LogEntry (..)
  , LogLevel (..)
  , LogSink
  , Logger
  , SourceLocation (..)
  , callbackSinkWith
  , componentText
  , defaultLogFilter
  , filterSource
  , flushLogger
  , logDebug
  , logInfo
  , mkLogger
  , mkLoggerWith
  , unsafeComponent
  , withBreadcrumb
  , withFields
  , writeEntry
  )
import Hetoimasia.Runtime.AsyncLog
  ( AsyncLogAdapter
  , AsyncLogConfig (..)
  , AsyncLogConfigError (..)
  , AsyncLogFlushFailure (AsyncLogFlushFailure)
  , AsyncLogStatus (..)
  , FlushOutcome (..)
  , adapterSink
  , adapterStatus
  , adapterStatusSTM
  , defaultAsyncLogConfig
  , flushAdapter
  , maxRetainedBreadcrumbs
  , maxRetainedFields
  , maximumTextBudget
  , minimumTextBudget
  , truncationComponent
  , truncationField
  , validateAsyncLogConfig
  , withAsyncLogAdapter
  )
import Hetoimasia.Runtime.Logging (flushFailures, lifetimeLogger, withLoggingLifetime)
import Hetoimasia.Runtime.Reporting (DiagnosticFailure)
import Test.Hspec
  ( Expectation
  , Spec
  , describe
  , expectationFailure
  , it
  , shouldBe
  , shouldReturn
  , shouldSatisfy
  , shouldThrow
  )
import Test.Runtime.LogFixture (fixedMetadata)
import Test.Support.Bounded (bounded)

spec ∷ Spec
spec = describe "Asynchronous logging adapter" $ do
  describe "Admission" $ do
    it "takes concurrent records and preserves attribution when it fits"
      (bounded testConcurrentAdmission)
    it "filters before preparing a payload and performs no sink I/O on a producer"
      (bounded testFilteringAndThreads)
    it "discards by severity when the record queue is full" (bounded testSaturation)

  describe "Bounded retention" $ do
    it "counts every textual member against one per-record byte budget"
      (bounded testByteAccounting)
    it "measures multibyte text in bytes and keeps whole code points"
      (bounded testMultibyteText)
    it "admits a record at the minimum budget, carrying its marker"
      (bounded testMinimumBudget)
    it "retains at most 64 field entries and counts the rest"
      (bounded testFieldCollectionBound)
    it "retains at most 32 breadcrumbs, counting empty ones"
      (bounded testBreadcrumbCollectionBound)
    it "rejects an out-of-range bound before a writer exists" testRejectedConfiguration

  describe "Flushing" $ do
    it "writes what was admitted before the barrier, and does not wait for what follows"
      (bounded testFlushOrdering)
    it "reports a failed underlying flush without inventing a record outcome"
      (bounded testFlushFailureAccounting)
    it "raises an unsuccessful barrier from the adapter sink's own flush"
      (bounded testSinkFlushRaises)
    it "wakes a waiting flush when the writer fails" (bounded testWriterFailureWakesWaiter)

  describe "Control requests" $ do
    it "rejects a request beyond the control bound without waiting"
      (bounded testControlBound)
    it "releases a cancelled waiter's registration, and does not accumulate them"
      (bounded testControlCancellationChurn)

  describe "Accounting" $ do
    it "separates successful, failed, and unattempted-abandoned records"
      (bounded testTerminalAccounting)

  describe "Cancellation" $ do
    it "interrupts a blocked write, joins the writer, and reports delivery unknown"
      (bounded testCancelInterruptibleBarrier)
    it "keeps the borrow open until an uncancellable write finishes"
      (bounded testCancelUncancellableBarrier)

  describe "Lifetime composition" $ do
    it "encloses the logging lifetime, whose final flush is the only flush"
      (bounded testEnclosesLoggingLifetime)
    it "keeps an application failure primary and rides the flush failure beside it"
      (bounded testPrimaryFailurePreserved)
    it "fails a successful run whose borrowed flush fails, marked as a diagnostic"
      (bounded testDiagnosticFlushFailure)

-- Fixtures ----------------------------------------------------------------------

testComponent ∷ Component
testComponent = unsafeComponent "test.async"

-- | The callback's own failure, distinguishable from any sink failure by type.
workFailure ∷ ErrorCall
workFailure = ErrorCall "adapter work exploded"

-- | What a borrowed sink does when the writer reaches it. Injected so an
-- example can block, fail, or hold an uncancellable region at a known point.
data Hooks = Hooks
  { hookWrite ∷ LogEntry → IO ()
  , hookFlush ∷ IO ()
  }

quiet ∷ Hooks
quiet = Hooks { hookWrite = \_ → pure (), hookFlush = pure () }

-- | A borrowed sink and everything an example can observe about it: the order
-- it was asked to do things in, what it actually accepted, and which threads
-- called it.
data Probe = Probe
  { probeSink ∷ LogSink
  , probeEntries ∷ IO [LogEntry]
  , probeTrace ∷ IO [Text]
  , probeThreads ∷ IO [ThreadId]
  }

newProbe ∷ Hooks → IO Probe
newProbe hooks = do
  entries ← newMVar []
  trace ← newMVar []
  threads ← newMVar []
  let write entry = do
        -- Traced before the hook, so the trace records attempts; collected
        -- after it, so a failed or interrupted write leaves nothing behind.
        note trace ("write " <> entryMessage entry)
        caller ← myThreadId
        modifyMVar_ threads (pure . (caller :))
        hookWrite hooks entry
        modifyMVar_ entries (pure . (entry :))
      flush = note trace "flush" >> hookFlush hooks
  pure Probe
    { probeSink = callbackSinkWith write flush
    , probeEntries = reverse <$> readMVar entries
    , probeTrace = readMVar trace
    , probeThreads = readMVar threads
    }

note ∷ MVar [Text] → Text → IO ()
note trace entry = modifyMVar_ trace (pure . (<> [entry]))

messages ∷ Probe → IO [Text]
messages probe = map entryMessage <$> probeEntries probe

-- | Run an adapter over a fresh probe and read the adapter's final account,
-- after the lifetime has joined its writer and abandoned what was left.
runAdapter
  ∷ AsyncLogConfig → Hooks → (Probe → AsyncLogAdapter → IO a) → IO (a, Probe, AsyncLogStatus)
runAdapter config hooks body = do
  probe ← newProbe hooks
  handle ← newEmptyMVar
  result ← withAsyncLogAdapter config (probeSink probe) $ \adapter → do
    putMVar handle adapter
    body probe adapter
  adapter ← readMVar handle
  status ← adapterStatus adapter
  pure (result, probe, status)

-- | A logger over the adapter sink, with fixed metadata and no source
-- attribution, for examples asserting on exact record contents.
adapterLogger ∷ AsyncLogAdapter → Logger
adapterLogger =
  mkLoggerWith defaultLogFilter { filterSource = False } fixedMetadata . adapterSink

-- | A prepared entry, so an example can fix every textual member exactly
-- instead of asking a logger to build one.
sample ∷ Text → LogEntry
sample message = LogEntry
  { entryLevel = Info
  , entryComponent = testComponent
  , entryMessage = message
  , entryFields = Map.empty
  , entryBreadcrumbs = []
  , entryTime = fixedTime
  , entryThread = "3"
  , entrySource = Nothing
  }

fixedTime ∷ UTCTime
fixedTime = UTCTime (fromGregorian 2026 9 20) (secondsToDiffTime 43200)

-- | Admit a prepared entry exactly as it stands, through the adapter sink.
offer ∷ AsyncLogAdapter → LogEntry → IO ()
offer adapter = writeEntry (adapterSink adapter)

-- | What the budget counts for one record.
retainedBytes ∷ LogEntry → Int
retainedBytes entry =
  lengthWord8 (entryMessage entry)
    + lengthWord8 (componentText (entryComponent entry))
    + sum [lengthWord8 key + lengthWord8 value | (key, value) ← Map.toList (entryFields entry)]
    + sum (map lengthWord8 (entryBreadcrumbs entry))
    + lengthWord8 (entryThread entry)
    + maybe 0 locationBytes (entrySource entry)
  where
    locationBytes location =
      lengthWord8 (sourceFile location) + lengthWord8 (sourceFunction location)

marker ∷ LogEntry → Maybe Text
marker = Map.lookup truncationField . entryFields

-- | Wait until the adapter's own account says this many control requests are
-- registered. A latch on the adapter's state, not a timing assumption.
awaitPending ∷ AsyncLogAdapter → Int → IO ()
awaitPending adapter wanted = atomically $ do
  status ← adapterStatusSTM adapter
  check (statusControlPending status == wanted)

expectFailure ∷ IO a → IO SomeException
expectFailure action = try action >>= either pure (\_ → fail "expected a failure, but it returned")

cancelled ∷ SomeException → Expectation
cancelled failure = (fromException failure ∷ Maybe AsyncException) `shouldBe` Just ThreadKilled

-- Admission ------------------------------------------------------------------------

testConcurrentAdmission ∷ IO ()
testConcurrentAdmission = do
  let producers = ["one", "two", "three", "four"]
      perProducer = 25 ∷ Int
  (_, probe, status) ← runAdapter defaultAsyncLogConfig quiet $ \_ adapter → do
    let root = mkLogger defaultLogFilter { filterSource = False } (adapterSink adapter)
    gate ← newEmptyMVar
    dones ← forM producers $ \name → do
      done ← newEmptyMVar
      void . forkIO $ do
        readMVar gate
        let producer = withBreadcrumb "worker" (withFields [("producer", name)] root)
        forM_ [1 .. perProducer] $ \index →
          logInfo producer testComponent "tick" [("seq", Text.pack (show index))]
        putMVar done ()
      pure (done ∷ MVar ())
    putMVar gate ()
    forM_ dones takeMVar
    flushAdapter adapter `shouldReturn` FlushCompleted
  entries ← probeEntries probe
  length entries `shouldBe` length producers * perProducer
  -- Attribution survives the hand-off, and nothing needed truncating.
  forM_ entries $ \entry → do
    entryComponent entry `shouldSatisfy` ((== "test.async") . componentText)
    entryBreadcrumbs entry `shouldBe` ["worker"]
    marker entry `shouldBe` Nothing
  forM_ producers $ \name →
    [ value
    | entry ← entries
    , Map.lookup "producer" (entryFields entry) == Just name
    , Just value ← [Map.lookup "seq" (entryFields entry)]
    ]
      `shouldBe` map (Text.pack . show) [1 .. perProducer]
  statusAdmitted status `shouldBe` length producers * perProducer
  statusWritten status `shouldBe` length producers * perProducer
  statusDropped status `shouldBe` Map.empty
  statusTruncated status `shouldBe` 0

testFilteringAndThreads ∷ IO ()
testFilteringAndThreads = do
  producer ← myThreadId
  (_, probe, status) ← runAdapter defaultAsyncLogConfig quiet $ \_ adapter → do
    let logger = adapterLogger adapter
    -- Debug is not selected, so neither the message nor the fields are forced:
    -- the filter runs before the adapter prepares any payload.
    logDebug logger testComponent (error "a suppressed message was forced")
      [("field", error "a suppressed field was forced")]
    logInfo logger testComponent "admitted" []
    flushAdapter adapter `shouldReturn` FlushCompleted
  messages probe `shouldReturn` ["admitted"]
  threads ← probeThreads probe
  threads `shouldSatisfy` not . null
  -- Formatting and borrowed-sink I/O happen only on the writer.
  threads `shouldSatisfy` all (/= producer)
  statusAdmitted status `shouldBe` 1

testSaturation ∷ IO ()
testSaturation = do
  entered ← newEmptyMVar
  hold ← newEmptyMVar
  let hooks = quiet
        { hookWrite = \entry → when (entryMessage entry == "held") $ do
            putMVar entered ()
            readMVar hold
        }
      config = defaultAsyncLogConfig { asyncQueueCapacity = 4 }
  (_, probe, status) ← runAdapter config hooks $ \_ adapter → do
    offer adapter (sample "held")
    -- The writer is inside the borrowed write, so the queue is empty and the
    -- next four fill it exactly.
    takeMVar entered
    forM_ [1 .. 4 ∷ Int] $ \index → offer adapter (sample ("queued " <> Text.pack (show index)))
    replicateM_ 3 (offer adapter (sample "lost") { entryLevel = Warning })
    replicateM_ 2 (offer adapter (sample "lost") { entryLevel = Error })
    putMVar hold ()
  statusAdmitted status `shouldBe` 5
  statusWritten status `shouldBe` 5
  -- Nothing waited for space and nothing was written by a producer.
  statusDropped status `shouldBe` Map.fromList [(Warning, 3), (Error, 2)]
  statusAbandoned status `shouldBe` 0
  messages probe `shouldReturn`
    ["held", "queued 1", "queued 2", "queued 3", "queued 4"]

-- Bounded retention -------------------------------------------------------------------

-- | A record whose members sum to exactly @budget@ bytes: four for the
-- component @test.async@ is not it, so the message carries the slack.
exactEntry ∷ Int → LogEntry
exactEntry budget = (sample (Text.replicate body "x"))
  { entryFields = Map.fromList [("k", "v")]
  , entryBreadcrumbs = ["a"]
  }
  where
    fixed =
      lengthWord8 (componentText testComponent) + lengthWord8 "3" + lengthWord8 "k"
        + lengthWord8 "v"
        + lengthWord8 "a"
    body = budget - fixed

testByteAccounting ∷ IO ()
testByteAccounting = do
  let budget = 512
      config = defaultAsyncLogConfig { asyncTextBudget = budget }
      atBudget = exactEntry budget
      overBudget = atBudget { entryMessage = entryMessage atBudget <> "y" }
      oversizedField =
        (sample "context")
          { entryFields = Map.fromList [("big", Text.replicate 10000 "z")] }
  (_, probe, status) ← runAdapter config quiet $ \_ adapter → do
    offer adapter atBudget
    offer adapter overBudget
    offer adapter oversizedField
    flushAdapter adapter `shouldReturn` FlushCompleted
  entries ← probeEntries probe
  case entries of
    [kept, shortened, dropped] → do
      -- Exactly at the budget: every member retained verbatim, no marker.
      retainedBytes kept `shouldBe` budget
      kept `shouldBe` atBudget
      marker kept `shouldBe` Nothing
      -- One byte over: admitted, bounded, and marked.
      retainedBytes shortened `shouldSatisfy` (<= budget)
      marker shortened `shouldBe` Just "msg"
      entryMessage shortened `shouldSatisfy` (`Text.isPrefixOf` entryMessage overBudget)
      -- A field entry too large for what is left is dropped whole, not kept.
      retainedBytes dropped `shouldSatisfy` (<= budget)
      Map.lookup "big" (entryFields dropped) `shouldBe` Nothing
      marker dropped `shouldBe` Just "fields=1"
      entryMessage dropped `shouldBe` "context"
    _ → expectationFailure ("expected three records, got " <> show (length entries))
  statusAdmitted status `shouldBe` 3
  statusTruncated status `shouldBe` 2

testMultibyteText ∷ IO ()
testMultibyteText = do
  let budget = minimumTextBudget
      config = defaultAsyncLogConfig { asyncTextBudget = budget }
      -- 100 characters, 300 bytes: a character count inside the budget that a
      -- byte count is not.
      wide = Text.replicate 100 "€"
      entry = sample wide
  (_, probe, _) ← runAdapter config quiet $ \_ adapter → do
    offer adapter entry
    flushAdapter adapter `shouldReturn` FlushCompleted
  entries ← probeEntries probe
  case entries of
    [only] → do
      Text.length wide `shouldSatisfy` (< budget)
      lengthWord8 wide `shouldSatisfy` (> budget)
      retainedBytes only `shouldSatisfy` (<= budget)
      marker only `shouldBe` Just "msg"
      -- Whole code points: the kept text is a prefix of the original, and every
      -- character in it is the one the producer wrote.
      entryMessage only `shouldSatisfy` (`Text.isPrefixOf` wide)
      entryMessage only `shouldSatisfy` Text.all (== '€')
      lengthWord8 (entryMessage only) `shouldBe` 3 * Text.length (entryMessage only)
    _ → expectationFailure "expected one record"

testMinimumBudget ∷ IO ()
testMinimumBudget = do
  let config = defaultAsyncLogConfig { asyncTextBudget = minimumTextBudget }
      -- A valid component far larger than the whole budget, with a message to
      -- match: neither can be kept, and the record is still admitted.
      huge = unsafeComponent (Text.replicate 5000 "a")
      entry = (sample (Text.replicate 5000 "m")) { entryComponent = huge }
  (_, probe, status) ← runAdapter config quiet $ \_ adapter → do
    offer adapter entry
    flushAdapter adapter `shouldReturn` FlushCompleted
  entries ← probeEntries probe
  case entries of
    [only] → do
      entryComponent only `shouldBe` truncationComponent
      retainedBytes only `shouldSatisfy` (<= minimumTextBudget)
      marker only `shouldBe` Just "msg,cmp"
    _ → expectationFailure "expected one record"
  statusAdmitted status `shouldBe` 1
  statusTruncated status `shouldBe` 1
  statusDropped status `shouldBe` Map.empty

testFieldCollectionBound ∷ IO ()
testFieldCollectionBound = do
  let supplied = 100 ∷ Int
      fields = Map.fromList [(key index, "v") | index ← [0 .. supplied - 1]]
      key index =
        let shown = show index
         in Text.pack ('k' : replicate (3 - length shown) '0' <> shown)
      entry = (sample "many fields") { entryFields = fields }
  (_, probe, _) ← runAdapter defaultAsyncLogConfig quiet $ \_ adapter → do
    offer adapter entry
    flushAdapter adapter `shouldReturn` FlushCompleted
  entries ← probeEntries probe
  case entries of
    [only] → do
      -- The marker is the adapter's own field, beside the retained ones.
      Map.size (Map.delete truncationField (entryFields only)) `shouldBe` maxRetainedFields
      marker only `shouldBe` Just (Text.pack ("fields=" <> show (supplied - maxRetainedFields)))
      Map.keys (Map.delete truncationField (entryFields only))
        `shouldBe` take maxRetainedFields (Map.keys fields)
    _ → expectationFailure "expected one record"

testBreadcrumbCollectionBound ∷ IO ()
testBreadcrumbCollectionBound = do
  let supplied = 40 ∷ Int
      -- Empty breadcrumbs cost no bytes, so only the collection bound can bite.
      entry = (sample "many crumbs") { entryBreadcrumbs = replicate supplied Text.empty }
  (_, probe, _) ← runAdapter defaultAsyncLogConfig quiet $ \_ adapter → do
    offer adapter entry
    flushAdapter adapter `shouldReturn` FlushCompleted
  entries ← probeEntries probe
  case entries of
    [only] → do
      length (entryBreadcrumbs only) `shouldBe` maxRetainedBreadcrumbs
      entryBreadcrumbs only `shouldSatisfy` all Text.null
      marker only
        `shouldBe` Just (Text.pack ("crumbs=" <> show (supplied - maxRetainedBreadcrumbs)))
    _ → expectationFailure "expected one record"

testRejectedConfiguration ∷ IO ()
testRejectedConfiguration = do
  let below = defaultAsyncLogConfig { asyncTextBudget = minimumTextBudget - 1 }
      above = defaultAsyncLogConfig { asyncTextBudget = maximumTextBudget + 1 }
      noQueue = defaultAsyncLogConfig { asyncQueueCapacity = 0 }
      noControl = defaultAsyncLogConfig { asyncControlCapacity = 0 }
  validateAsyncLogConfig defaultAsyncLogConfig `shouldBe` Right defaultAsyncLogConfig
  validateAsyncLogConfig below `shouldBe` Left (TextBudgetRejected (minimumTextBudget - 1))
  validateAsyncLogConfig above `shouldBe` Left (TextBudgetRejected (maximumTextBudget + 1))
  validateAsyncLogConfig noQueue `shouldBe` Left (QueueCapacityRejected 0)
  validateAsyncLogConfig noControl `shouldBe` Left (ControlCapacityRejected 0)
  validateAsyncLogConfig defaultAsyncLogConfig { asyncTextBudget = minimumTextBudget }
    `shouldSatisfy` either (const False) (const True)
  -- The rejection is the caller's, raised before a writer exists: the borrowed
  -- sink is never touched and nothing is latched.
  probe ← newProbe quiet
  withAsyncLogAdapter below (probeSink probe) (\_ → pure ())
    `shouldThrow` (== TextBudgetRejected (minimumTextBudget - 1))
  withAsyncLogAdapter noQueue (probeSink probe) (\_ → pure ())
    `shouldThrow` (== QueueCapacityRejected 0)
  probeTrace probe `shouldReturn` []

-- Flushing ---------------------------------------------------------------------------

testFlushOrdering ∷ IO ()
testFlushOrdering = do
  entered ← newEmptyMVar
  hold ← newEmptyMVar
  let hooks = quiet
        { hookWrite = \entry → when (entryMessage entry == "first") $ do
            putMVar entered ()
            takeMVar hold
        }
  (outcome, probe, status) ← runAdapter defaultAsyncLogConfig hooks $ \_ adapter → do
    offer adapter (sample "first")
    takeMVar entered
    offer adapter (sample "second")
    -- The barrier is taken here: it covers the two records already admitted.
    flushed ← newEmptyMVar
    void (forkIO (flushAdapter adapter >>= putMVar flushed))
    awaitPending adapter 1
    -- Admitted after the request, so it must not extend the barrier.
    offer adapter (sample "third")
    putMVar hold ()
    takeMVar flushed
  outcome `shouldBe` FlushCompleted
  trace ← probeTrace probe
  trace `shouldBe` ["write first", "write second", "flush", "write third"]
  statusWritten status `shouldBe` 3
  -- A successful barrier resets nothing.
  statusAdmitted status `shouldBe` 3

testFlushFailureAccounting ∷ IO ()
testFlushFailureAccounting = do
  let hooks = quiet { hookFlush = ioError (userError "flush unavailable") }
  (outcome, probe, status) ← runAdapter defaultAsyncLogConfig hooks $ \_ adapter → do
    offer adapter (sample "one")
    offer adapter (sample "two")
    flushAdapter adapter
  case outcome of
    FlushWriterFailed reason → reason `shouldSatisfy` Text.isInfixOf "flush unavailable"
    other → expectationFailure ("expected a latched writer failure, got " <> show other)
  messages probe `shouldReturn` ["one", "two"]
  -- A flush outcome is not a record outcome.
  statusWritten status `shouldBe` 2
  statusFailedWrites status `shouldBe` 0
  statusInterruptedWrites status `shouldBe` 0
  statusAbandoned status `shouldBe` 0
  statusWriterTerminated status `shouldBe` True
  statusWriterFailure status `shouldSatisfy` maybe False (Text.isInfixOf "flush unavailable")
  -- A request made after termination observes it rather than waiting.
  (later, _, _) ← runAdapter defaultAsyncLogConfig hooks $ \_ adapter → do
    void (flushAdapter adapter)
    flushAdapter adapter
  case later of
    FlushWriterFailed _ → pure ()
    other → expectationFailure ("expected the latched failure again, got " <> show other)

testSinkFlushRaises ∷ IO ()
testSinkFlushRaises = do
  let hooks = quiet { hookFlush = ioError (userError "flush unavailable") }
  (_, _, status) ← runAdapter defaultAsyncLogConfig hooks $ \_ adapter → do
    let logger = adapterLogger adapter
    logInfo logger testComponent "recorded" []
    -- The adapter sink's flush is the same barrier, raised synchronously.
    flushLogger logger `shouldThrow` unsuccessfulBarrier
  statusWritten status `shouldBe` 1
  statusFailedWrites status `shouldBe` 0
  where
    unsuccessfulBarrier (AsyncLogFlushFailure outcome) = case outcome of
      FlushCompleted → False
      _ → True

testWriterFailureWakesWaiter ∷ IO ()
testWriterFailureWakesWaiter = do
  entered ← newEmptyMVar
  hold ← newEmptyMVar
  let hooks = quiet
        { hookWrite = \entry → when (entryMessage entry == "doomed") $ do
            putMVar entered ()
            takeMVar hold
            ioError (userError "sink unavailable")
        }
  (outcome, probe, status) ← runAdapter defaultAsyncLogConfig hooks $ \_ adapter → do
    offer adapter (sample "doomed")
    takeMVar entered
    flushed ← newEmptyMVar
    void (forkIO (flushAdapter adapter >>= putMVar flushed))
    awaitPending adapter 1
    -- The waiter is registered and the barrier can never complete.
    putMVar hold ()
    takeMVar flushed
  case outcome of
    FlushWriterFailed reason → reason `shouldSatisfy` Text.isInfixOf "sink unavailable"
    other → expectationFailure ("expected the writer's failure, got " <> show other)
  messages probe `shouldReturn` []
  statusFailedWrites status `shouldBe` 1
  statusWritten status `shouldBe` 0
  statusWriterTerminated status `shouldBe` True

-- Control requests -----------------------------------------------------------------------

testControlBound ∷ IO ()
testControlBound = do
  entered ← newEmptyMVar
  hold ← newEmptyMVar
  let hooks = quiet
        { hookWrite = \entry → when (entryMessage entry == "held") $ do
            putMVar entered ()
            readMVar hold
        }
      config = defaultAsyncLogConfig { asyncControlCapacity = 2 }
  (rejected, _, _) ← runAdapter config hooks $ \_ adapter → do
    offer adapter (sample "held")
    takeMVar entered
    waiters ← forM [1 .. 2 ∷ Int] $ \_ → do
      slot ← newEmptyMVar
      void (forkIO (flushAdapter adapter >>= putMVar slot))
      pure slot
    awaitPending adapter 2
    -- The third request neither waits for record-queue space nor blocks.
    outcome ← flushAdapter adapter
    putMVar hold ()
    forM_ waiters (\slot → takeMVar slot `shouldReturn` FlushCompleted)
    pure outcome
  rejected `shouldBe` FlushRejected

testControlCancellationChurn ∷ IO ()
testControlCancellationChurn = do
  entered ← newEmptyMVar
  hold ← newEmptyMVar
  let hooks = quiet
        { hookWrite = \entry → when (entryMessage entry == "held") $ do
            putMVar entered ()
            readMVar hold
        }
      config = defaultAsyncLogConfig { asyncControlCapacity = 1 }
  (_, _, _) ← runAdapter config hooks $ \_ adapter → do
    offer adapter (sample "held")
    takeMVar entered
    -- Registering and cancelling with the writer blocked accumulates nothing:
    -- were a registration orphaned, the bound of one would reject the next.
    replicateM_ 50 $ do
      waiter ← forkIO (void (flushAdapter adapter))
      awaitPending adapter 1
      killThread waiter
      awaitPending adapter 0
    -- The slot is usable again after all that churn.
    slot ← newEmptyMVar
    void (forkIO (flushAdapter adapter >>= putMVar slot))
    awaitPending adapter 1
    putMVar hold ()
    takeMVar slot `shouldReturn` FlushCompleted
  pure ()

-- Accounting ------------------------------------------------------------------------------

testTerminalAccounting ∷ IO ()
testTerminalAccounting = do
  entered ← newEmptyMVar
  hold ← newEmptyMVar
  let hooks = quiet
        { hookWrite = \entry → case entryMessage entry of
            "held" → putMVar entered () >> takeMVar hold
            "boom" → ioError (userError "sink unavailable")
            _ → pure ()
        }
  (_, probe, status) ← runAdapter defaultAsyncLogConfig hooks $ \_ adapter → do
    offer adapter (sample "held")
    takeMVar entered
    -- Queued behind the blocked write, so the writer meets them in this order.
    forM_ ["second", "boom", "never 1", "never 2", "never 3"] $ \message →
      offer adapter (sample message)
    putMVar hold ()
  -- The completed writes stay completed; the failure is one record with
  -- delivery unknown; what the writer never reached is abandoned, not failed.
  statusAdmitted status `shouldBe` 6
  statusWritten status `shouldBe` 2
  statusFailedWrites status `shouldBe` 1
  statusInterruptedWrites status `shouldBe` 0
  statusAbandoned status `shouldBe` 3
  statusWriterTerminated status `shouldBe` True
  statusWriterFailure status `shouldSatisfy` maybe False (Text.isInfixOf "sink unavailable")
  messages probe `shouldReturn` ["held", "second"]
  trace ← probeTrace probe
  -- Nothing after the failed record was attempted.
  trace `shouldBe` ["write held", "write second", "write boom"]

-- Cancellation ---------------------------------------------------------------------------

-- | Run a lifetime on its own thread, hand back its adapter handle, and return
-- the outcome once the example has cancelled it.
cancellableAdapter
  ∷ Hooks
  → (AsyncLogAdapter → IO ())
  → IO (Probe, MVar AsyncLogAdapter, MVar (Either SomeException ()), ThreadId)
cancellableAdapter hooks body = do
  probe ← newProbe hooks
  handle ← newEmptyMVar
  outcome ← newEmptyMVar
  runner ← forkIO $ do
    result ← try . withAsyncLogAdapter defaultAsyncLogConfig (probeSink probe) $ \adapter → do
      putMVar handle adapter
      body adapter
    putMVar outcome result
  pure (probe, handle, outcome, runner)

testCancelInterruptibleBarrier ∷ IO ()
testCancelInterruptibleBarrier = do
  entered ← newEmptyMVar
  hold ← newEmptyMVar
  let hooks = quiet { hookWrite = \_ → putMVar entered () >> takeMVar hold }
  (probe, handle, outcome, runner) ← cancellableAdapter hooks $ \adapter → do
    offer adapter (sample "in flight")
    void (flushAdapter adapter)
  takeMVar entered
  adapter ← readMVar handle
  -- The owner is parked on the barrier and the writer is inside the borrowed
  -- write, which is an interruptible wait.
  awaitPending adapter 1
  killThread runner
  result ← bounded (takeMVar outcome)
  either cancelled (\_ → expectationFailure "the cancelled lifetime returned") result
  status ← adapterStatus adapter
  -- The interrupted record is neither replayed nor called undelivered.
  statusInterruptedWrites status `shouldBe` 1
  statusWritten status `shouldBe` 0
  statusFailedWrites status `shouldBe` 0
  statusAbandoned status `shouldBe` 0
  statusWriterTerminated status `shouldBe` True
  statusWriterFailure status `shouldBe` Nothing
  -- The writer was joined, and the borrowed sink never accepted the record.
  messages probe `shouldReturn` []
  probeTrace probe `shouldReturn` ["write in flight"]

testCancelUncancellableBarrier ∷ IO ()
testCancelUncancellableBarrier = do
  entered ← newEmptyMVar
  gate ← newEmptyMVar
  completed ← newMVar (0 ∷ Int)
  -- A borrowed write no cancellation can shorten: only this example's own gate
  -- lets it finish.
  let hooks = quiet
        { hookWrite = \_ → uninterruptibleMask_ $ do
            putMVar entered ()
            takeMVar gate
            modifyMVar_ completed (pure . (+ 1))
        }
  (probe, handle, outcome, runner) ← cancellableAdapter hooks $ \adapter → do
    offer adapter (sample "uncancellable")
    void (flushAdapter adapter)
  takeMVar entered
  adapter ← readMVar handle
  awaitPending adapter 1
  -- The writer is inside the borrowed write and the owner is on the barrier.
  probeTrace probe `shouldReturn` ["write uncancellable"]
  -- Two cancellations while that write is held: neither ends the drain, and
  -- neither releases the borrow early.
  killThread runner
  killThread runner
  held ← tryTakeMVar outcome
  case held of
    Nothing → pure ()
    Just _ → expectationFailure "the lifetime returned while its writer held the sink"
  readMVar completed `shouldReturn` 0
  -- Releasing this example's own gate is the only thing that lets it finish.
  putMVar gate ()
  result ← bounded (takeMVar outcome)
  either cancelled (\_ → expectationFailure "the cancelled lifetime returned") result
  -- The borrowed write ran to completion with the sink still live, and the
  -- writer was joined rather than detached.
  readMVar completed `shouldReturn` 1
  status ← adapterStatus adapter
  statusWriterTerminated status `shouldBe` True
  statusFailedWrites status `shouldBe` 0
  statusAbandoned status `shouldBe` 0
  -- The record is accounted exactly once. Whether the cancellation caught the
  -- writer inside that write or just after it is the sink's timing, not a
  -- promise the adapter makes: either way it is never counted twice and never
  -- claimed delivered.
  statusWritten status + statusInterruptedWrites status `shouldBe` 1

-- Lifetime composition ----------------------------------------------------------------------

testEnclosesLoggingLifetime ∷ IO ()
testEnclosesLoggingLifetime = do
  (_, probe, status) ← runAdapter defaultAsyncLogConfig quiet $ \_ adapter →
    withLoggingLifetime (adapterLogger adapter) $ \lifetime →
      logInfo (lifetimeLogger lifetime) testComponent "work" []
  -- The logging lifetime's own final flush is the only flush: adapter shutdown
  -- adds no second one.
  probeTrace probe `shouldReturn` ["write work", "flush"]
  statusWritten status `shouldBe` 1
  statusAbandoned status `shouldBe` 0
  -- The borrowed sink's resources stayed the caller's throughout.
  writeEntry (probeSink probe) (sample "after the adapter")
  messages probe `shouldReturn` ["work", "after the adapter"]

testPrimaryFailurePreserved ∷ IO ()
testPrimaryFailurePreserved = do
  probe ← newProbe quiet { hookFlush = ioError (userError "flush unavailable") }
  failure ← expectFailure . withAsyncLogAdapter defaultAsyncLogConfig (probeSink probe) $
    \adapter →
      withLoggingLifetime (adapterLogger adapter) $ \lifetime → do
        logInfo (lifetimeLogger lifetime) testComponent "work" []
        throwIO workFailure
  -- The application's failure stays primary, and the adapter raises no latched
  -- writer failure of its own.
  (show <$> (fromException failure ∷ Maybe ErrorCall)) `shouldBe` Just (show workFailure)
  case flushFailures failure of
    [] → expectationFailure "the failed final flush left no secondary evidence"
    evidence → length evidence `shouldBe` 1
  probeTrace probe `shouldReturn` ["write work", "flush"]

testDiagnosticFlushFailure ∷ IO ()
testDiagnosticFlushFailure = do
  probe ← newProbe quiet { hookFlush = ioError (userError "flush unavailable") }
  failure ← expectFailure . withAsyncLogAdapter defaultAsyncLogConfig (probeSink probe) $
    \adapter →
      withLoggingLifetime (adapterLogger adapter) $ \lifetime →
        logInfo (lifetimeLogger lifetime) testComponent "work" []
  -- A successful run whose final flush failed fails with the barrier's own
  -- exception, marked by the logging lifetime as a diagnostic failure.
  case fromException failure ∷ Maybe AsyncLogFlushFailure of
    Just (AsyncLogFlushFailure (FlushWriterFailed reason)) →
      reason `shouldSatisfy` Text.isInfixOf "flush unavailable"
    other → expectationFailure ("expected an unsuccessful barrier, got " <> show other)
  let marks = getExceptionAnnotations (someExceptionContext failure) ∷ [DiagnosticFailure]
  length marks `shouldBe` 1
  probeTrace probe `shouldReturn` ["write work", "flush"]
