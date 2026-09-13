-- | Examples for 'Hetoimasia.Runtime.Logging', the borrowed logging lifetime
-- and its final flush.
--
-- Every example observes what an owner can see: the result or the failure that
-- left the lifetime with its evidence, an append-only trace of sink writes,
-- flushes, releases, and callback steps, and the reporting outcomes recorded on
-- the handle.
--
-- Cancellation is coordinated with 'MVar's, never with a sleep; 'bounded' only
-- stops an example that has already hung.
module Test.Engine.Runtime.Lifetime (spec) where

import Control.Concurrent (forkIO, killThread)
import Control.Concurrent.MVar
  ( MVar
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
  , ExceptionWithContext (ExceptionWithContext)
  , IOException
  , MaskingState (MaskedUninterruptible, Unmasked)
  , SomeException
  , annotateIO
  , bracket
  , finally
  , fromException
  , getMaskingState
  , someExceptionContext
  , throwIO
  , try
  , tryWithContext
  )
import Control.Exception.Annotation (ExceptionAnnotation (displayExceptionAnnotation))
import Control.Exception.Context (ExceptionContext, getExceptionAnnotations)
import Control.Monad (when)
import Data.Text (Text)
import Hetoimasia.Foundation.Failure
  ( FailureCause (..)
  , FailureEvidence (..)
  , FailureOrigin (..)
  , failureEvidenceInContext
  , operation
  , throwFailure
  )
import Hetoimasia.Foundation.Log
  ( Component
  , LogEntry (..)
  , LogLevel (..)
  , LogSink
  , Logger
  , componentText
  , callbackSinkWith
  , defaultFormatOptions
  , defaultLogFilter
  , formatFlush
  , logInfo
  , mkLogger
  , newHandleSinkWith
  , unsafeComponent
  )
import Hetoimasia.Foundation.Resource
  ( allocResource
  , cleanupFailureLabel
  , cleanupFailuresInContext
  , withResourceLabelled
  , withScoped
  )
import Hetoimasia.Runtime.Logging
  ( LoggingLifetime
  , failedReports
  , failedReportsInContext
  , flushFailures
  , flushFailuresInContext
  , lifetimeLogger
  , recordReport
  , recordedReports
  , withHandleLoggingLifetime
  , withLoggingLifetime
  )
import Hetoimasia.Runtime.Reporting
  ( DiagnosticFailure (..)
  , ReportResult (..)
  , markDiagnostic
  , reportTerminalFailureWith
  , terminalReportAttempted
  )
import Hetoimasia.Runtime.Resources (managedResourceSmoke, smokeWork, workingReleases)
import System.Directory (getFileSize)
import System.FilePath ((</>))
import System.IO
  ( BufferMode (BlockBuffering)
  , IOMode (WriteMode)
  , hClose
  , hGetBuffering
  , hIsOpen
  , hSetBuffering
  , openFile
  )
import System.IO.Error (ioeGetErrorString)
import System.IO.Temp (withSystemTempDirectory)
import Test.Engine.Logging.Support (bounded)
import Test.Hspec
  ( Expectation
  , Spec
  , describe
  , expectationFailure
  , it
  , shouldBe
  , shouldReturn
  )

spec ∷ Spec
spec = describe "Logging lifetime" $ do
  describe "Finalization" $ do
    it "returns the callback's result after one final flush" testSuccess
    it "fails a successful run whose final flush fails" testSuccessFlushFails
    it "rethrows a callback failure after one final flush" testFailureFlushes
    it "keeps a callback failure primary, with its evidence, when the flush also fails"
      testFailureFlushFails
    it "returns a result without flushing once a managed report has failed"
      testKnownFailedSuccess
    it "rethrows without flushing once a managed report has failed, exposing the attempt"
      testKnownFailedFailure
    it "makes no flush after a marked diagnostic failed" testMarkedDiagnostic

  describe "Cancellation" $ do
    it "propagates a cancellation the callback raised, with its context and no flush"
      testCancellationContext
    it "propagates a cancellation delivered to the callback, with no flush"
      (bounded testCancelledCallback)
    it "propagates a cancellation delivered while the owner's report blocks, with no flush"
      (bounded testCancelledReport)
    it "propagates a cancellation delivered while the final flush blocks, unretried"
      (bounded testCancelledFlush)

  describe "Ordering" $ do
    it "flushes after producers, scopes, and the report, outside every release"
      testOrdering
    it "leaves a borrowed handle open with its buffering unchanged" testBorrowedHandle

  describe "Managed resource smoke" $ do
    it "runs the smoke records and then one final flush" testManagedSmoke
    it "hands a failed report to the lifetime owner while the work's failure propagates"
      testManagedSmokeReportFails

-- Fixtures --------------------------------------------------------------------

lifetimeComponent ∷ Component
lifetimeComponent = unsafeComponent "test.lifetime"

-- | The callback's own failure, distinguishable from any sink failure by type.
workFailure ∷ ErrorCall
workFailure = ErrorCall "lifetime work exploded"

-- | Rides on the exception a flush or a callback raises, so an example can tell
-- that exception, with its own context, from a copy of it.
data Mark = Mark
  deriving (Eq, Show)

instance ExceptionAnnotation Mark where
  displayExceptionAnnotation _ = "raised by the example"

note ∷ MVar [Text] → Text → IO ()
note trace entry = modifyMVar_ trace (pure . (<> [entry]))

-- | A sink that traces every write as @write <message>@ and every flush as
-- @flush@, then runs the injected write and flush outcomes.
tracedSink ∷ MVar [Text] → (LogEntry → IO ()) → IO () → LogSink
tracedSink trace onWrite onFlush =
  callbackSinkWith
    (\entry → note trace ("write " <> entryMessage entry) >> onWrite entry)
    (note trace "flush" >> onFlush)

tracedLogger ∷ MVar [Text] → (LogEntry → IO ()) → IO () → Logger
tracedLogger trace onWrite onFlush = mkLogger defaultLogFilter (tracedSink trace onWrite onFlush)

flushCount ∷ MVar [Text] → IO Int
flushCount trace = length . filter (== "flush") <$> readMVar trace

-- | A flush that fails synchronously, with a mark on its own context.
failingFlush ∷ IO ()
failingFlush = annotateIO Mark (ioError (userError "flush failed"))

-- | A write that fails for 'Error' entries, the level terminal reports use.
failOnError ∷ LogEntry → IO ()
failOnError entry = when (entryLevel entry == Error) (ioError (userError "sink unavailable"))

-- | Require the action to fail, and return what propagated with its context.
expectFailure ∷ IO a → IO SomeException
expectFailure action = try action >>= either pure (\_ → fail "expected a failure, but it returned")

ioMessage ∷ SomeException → Maybe String
ioMessage failure = ioeGetErrorString <$> (fromException failure ∷ Maybe IOException)

attemptMessages ∷ [ExceptionWithContext SomeException] → [Maybe String]
attemptMessages attempts = [ioMessage failure | ExceptionWithContext _ failure ← attempts]

diagnosticMarks ∷ ExceptionContext → [DiagnosticFailure]
diagnosticMarks = getExceptionAnnotations

-- | Signals that it has arrived, then blocks on an 'MVar' the example holds and
-- never fills, which keeps the block interruptible rather than a deadlock.
blockedAt ∷ MVar () → MVar () → IO a
blockedAt entered held = do
  putMVar entered ()
  takeMVar held
  throwIO (ErrorCall "a blocked action was released")

-- | Run a lifetime on its own thread and kill that thread once @entered@ proves
-- it has parked at an interruptible point.
cancelledLifetime ∷ Logger → (LoggingLifetime → IO ()) → MVar () → IO (Either SomeException ())
cancelledLifetime logger callback entered = do
  outcome ← newEmptyMVar
  runner ← forkIO $ try (withLoggingLifetime logger callback) >>= putMVar outcome
  takeMVar entered
  killThread runner
  takeMVar outcome

cancelled ∷ Either SomeException () → Expectation
cancelled (Right ()) = expectationFailure "the cancelled lifetime returned"
cancelled (Left failure) = do
  (fromException failure ∷ Maybe AsyncException) `shouldBe` Just ThreadKilled
  -- Never converted into a synchronous logger failure.
  diagnosticMarks (someExceptionContext failure) `shouldBe` []

-- | The managed terminal report the examples make inside a lifetime, around
-- work that fails.
reportedWork ∷ LoggingLifetime → IO ()
reportedWork lifetime =
  reportTerminalFailureWith (recordReport lifetime) (lifetimeLogger lifetime)
    lifetimeComponent "Work abandoned" (pure []) (throwIO workFailure)

-- Finalization ----------------------------------------------------------------

testSuccess ∷ Expectation
testSuccess = do
  trace ← newMVar []
  let logger = tracedLogger trace (const (pure ())) (pure ())
  result ← withLoggingLifetime logger $ \lifetime → do
    logInfo (lifetimeLogger lifetime) lifetimeComponent "working" []
    note trace "callback returned"
    pure (42 ∷ Int)
  result `shouldBe` 42
  readMVar trace `shouldReturn` ["write working", "callback returned", "flush"]

testSuccessFlushFails ∷ Expectation
testSuccessFlushFails = do
  trace ← newMVar []
  let logger = tracedLogger trace (const (pure ())) failingFlush
  propagated ← expectFailure (withLoggingLifetime logger (\_ → pure (42 ∷ Int)))
  -- The flush's own exception fails the run, with its context and marked as a
  -- diagnostic so no enclosing boundary reports through the failed sink.
  ioMessage propagated `shouldBe` Just "flush failed"
  getExceptionAnnotations (someExceptionContext propagated) `shouldBe` [Mark]
  diagnosticMarks (someExceptionContext propagated) `shouldBe` [DiagnosticFailure]
  flushCount trace `shouldReturn` 1

testFailureFlushes ∷ Expectation
testFailureFlushes = do
  trace ← newMVar []
  let logger = tracedLogger trace (const (pure ())) (pure ())
  propagated ← expectFailure (withLoggingLifetime logger (\_ → throwIO workFailure ∷ IO ()))
  (fromException propagated ∷ Maybe ErrorCall) `shouldBe` Just workFailure
  length (flushFailures propagated) `shouldBe` 0
  readMVar trace `shouldReturn` ["flush"]

testFailureFlushFails ∷ Expectation
testFailureFlushFails = do
  trace ← newMVar []
  let logger = tracedLogger trace (const (pure ())) failingFlush
      callback _ =
        withResourceLabelled
          "journal"
          (pure ())
          (\_ → ioError (userError "journal release failed"))
          (\_ → throwFailure lifetimeComponent (operation "load journal") [("id", "7")] workFailure)
  -- A typed, context-aware catch still recognizes the primary.
  outcome ← tryWithContext (withLoggingLifetime logger callback ∷ IO ())
  ExceptionWithContext context raised ←
    either pure (\_ → fail "expected the callback's failure") outcome
  raised `shouldBe` workFailure
  -- Its origin and its cleanup evidence survive, and no cleanup entry was
  -- forged for the flush.
  case failureCause (failureEvidenceInContext context) of
    EngineOrigin origin → componentText (originComponent origin) `shouldBe` "test.lifetime"
    NativeCause → expectationFailure "the primary's origin was lost"
  map cleanupFailureLabel (cleanupFailuresInContext context) `shouldBe` ["journal"]
  -- The flush failure is secondary evidence with its own type, value, and
  -- context.
  case flushFailuresInContext context of
    [ExceptionWithContext flushContext secondary] → do
      ioMessage secondary `shouldBe` Just "flush failed"
      getExceptionAnnotations flushContext `shouldBe` [Mark]
    other → expectationFailure ("expected one flush failure, found " <> show (length other))
  length (failedReportsInContext context) `shouldBe` 0
  flushCount trace `shouldReturn` 1

testKnownFailedSuccess ∷ Expectation
testKnownFailedSuccess = do
  trace ← newMVar []
  let logger = tracedLogger trace failOnError (pure ())
  (result, recorded) ← withLoggingLifetime logger $ \lifetime → do
    -- The owner handles the failure it reported and returns normally.
    _ ← try (reportedWork lifetime) ∷ IO (Either ErrorCall ())
    recorded ← recordedReports lifetime
    pure (7 ∷ Int, recorded)
  result `shouldBe` 7
  [ioMessage failure | ReportFailed (ExceptionWithContext _ failure) ← recorded]
    `shouldBe` [Just "sink unavailable"]
  -- One attempt, never repeated, and no flush through the failed path.
  readMVar trace `shouldReturn` ["write Work abandoned"]

testKnownFailedFailure ∷ Expectation
testKnownFailedFailure = do
  trace ← newMVar []
  slot ← newEmptyMVar
  let logger = tracedLogger trace failOnError (pure ())
  propagated ←
    expectFailure $ withLoggingLifetime logger $ \lifetime →
      putMVar slot lifetime >> reportedWork lifetime
  (fromException propagated ∷ Maybe ErrorCall) `shouldBe` Just workFailure
  terminalReportAttempted propagated `shouldBe` True
  attemptMessages (failedReports propagated) `shouldBe` [Just "sink unavailable"]
  length (flushFailures propagated) `shouldBe` 0
  lifetime ← readMVar slot
  recorded ← recordedReports lifetime
  length [() | ReportFailed _ ← recorded] `shouldBe` 1
  readMVar trace `shouldReturn` ["write Work abandoned"]

testMarkedDiagnostic ∷ Expectation
testMarkedDiagnostic = do
  trace ← newMVar []
  let logger = tracedLogger trace (\_ → ioError (userError "sink unavailable")) (pure ())
  propagated ←
    expectFailure $ withLoggingLifetime logger $ \lifetime →
      markDiagnostic (logInfo (lifetimeLogger lifetime) lifetimeComponent "Lifecycle record" [])
  ioMessage propagated `shouldBe` Just "sink unavailable"
  diagnosticMarks (someExceptionContext propagated) `shouldBe` [DiagnosticFailure]
  readMVar trace `shouldReturn` ["write Lifecycle record"]

-- Cancellation ----------------------------------------------------------------

testCancellationContext ∷ Expectation
testCancellationContext = do
  trace ← newMVar []
  let logger = tracedLogger trace (const (pure ())) (pure ())
  propagated ←
    expectFailure (withLoggingLifetime logger (\_ → annotateIO Mark (throwIO ThreadKilled) ∷ IO ()))
  (fromException propagated ∷ Maybe AsyncException) `shouldBe` Just ThreadKilled
  getExceptionAnnotations (someExceptionContext propagated) `shouldBe` [Mark]
  flushCount trace `shouldReturn` 0

testCancelledCallback ∷ Expectation
testCancelledCallback = do
  trace ← newMVar []
  entered ← newEmptyMVar
  held ← newEmptyMVar
  let logger = tracedLogger trace (const (pure ())) (pure ())
  outcome ← cancelledLifetime logger (\_ → blockedAt entered held) entered
  cancelled outcome
  flushCount trace `shouldReturn` 0

testCancelledReport ∷ Expectation
testCancelledReport = do
  trace ← newMVar []
  entered ← newEmptyMVar
  held ← newEmptyMVar
  slot ← newEmptyMVar
  let blockOnError entry = when (entryLevel entry == Error) (blockedAt entered held)
      logger = tracedLogger trace blockOnError (pure ())
  outcome ←
    cancelledLifetime logger (\lifetime → putMVar slot lifetime >> reportedWork lifetime) entered
  -- The work had already failed synchronously; the cancellation still wins.
  cancelled outcome
  flushCount trace `shouldReturn` 0
  lifetime ← readMVar slot
  length <$> recordedReports lifetime `shouldReturn` 0

testCancelledFlush ∷ Expectation
testCancelledFlush = do
  trace ← newMVar []
  entered ← newEmptyMVar
  held ← newEmptyMVar
  let logger = tracedLogger trace (const (pure ())) (blockedAt entered held)
  outcome ← cancelledLifetime logger (\_ → pure ()) entered
  cancelled outcome
  -- The one attempt was made, interrupted, and not retried.
  flushCount trace `shouldReturn` 1

-- Ordering --------------------------------------------------------------------

testOrdering ∷ Expectation
testOrdering = do
  trace ← newMVar []
  flushMasking ← newEmptyMVar
  releaseMasking ← newEmptyMVar
  let logger = tracedLogger trace (const (pure ())) (getMaskingState >>= putMVar flushMasking)
  propagated ←
    expectFailure $ withLoggingLifetime logger $ \lifetime → do
      let scoped = lifetimeLogger lifetime
          resource =
            allocResource
              (note trace "acquire")
              (\() → getMaskingState >>= putMVar releaseMasking >> note trace "release")
      -- The owner's terminal report wraps the scope, so it runs once the scope
      -- has unwound; the producer is joined inside the scope.
      reportTerminalFailureWith (recordReport lifetime) scoped lifetimeComponent "Work abandoned"
        (pure [])
        (withScoped resource $ \() → do
          joined ← newEmptyMVar
          _ ← forkIO (logInfo scoped lifetimeComponent "produced" [] `finally` putMVar joined ())
          takeMVar joined
          note trace "producer joined"
          throwIO workFailure)
        `finally` note trace "callback finished"
  (fromException propagated ∷ Maybe ErrorCall) `shouldBe` Just workFailure
  -- The flush follows the producer, the release, and the report, and no step
  -- after the callback writes again.
  readMVar trace `shouldReturn`
    [ "acquire"
    , "write produced"
    , "producer joined"
    , "release"
    , "write Work abandoned"
    , "callback finished"
    , "flush"
    ]
  -- The release ran uninterruptibly; the flush ran outside it, unmasked.
  takeMVar releaseMasking `shouldReturn` MaskedUninterruptible
  takeMVar flushMasking `shouldReturn` Unmasked

testBorrowedHandle ∷ Expectation
testBorrowedHandle =
  withSystemTempDirectory "hetoimasia-logging-lifetime" $ \directory → do
    let unflushed = directory </> "unflushed.log"
        convenience = directory </> "convenience.log"
        buffering = BlockBuffering (Just 65536)
    -- A sink that never flushes per record, so only the final flush can move
    -- the record out of the handle's buffer while the handle stays open.
    bracket (openFile unflushed WriteMode) closeIfOpen $ \handle → do
      hSetBuffering handle buffering
      sink ← newHandleSinkWith defaultFormatOptions { formatFlush = False } handle
      withLoggingLifetime (mkLogger defaultLogFilter sink) $ \lifetime →
        logInfo (lifetimeLogger lifetime) lifetimeComponent "Buffered record" []
      size ← getFileSize unflushed
      (size > 0) `shouldBe` True
      hIsOpen handle `shouldReturn` True
      hGetBuffering handle `shouldReturn` buffering
    -- The convenience wrapper borrows the handle the same way.
    bracket (openFile convenience WriteMode) closeIfOpen $ \handle → do
      hSetBuffering handle buffering
      withHandleLoggingLifetime defaultLogFilter handle $ \lifetime →
        logInfo (lifetimeLogger lifetime) lifetimeComponent "Borrowed record" []
      hIsOpen handle `shouldReturn` True
      hGetBuffering handle `shouldReturn` buffering
  where
    closeIfOpen handle = hIsOpen handle >>= \open → when open (hClose handle)

-- Managed resource smoke ------------------------------------------------------

testManagedSmoke ∷ Expectation
testManagedSmoke = do
  trace ← newMVar []
  let logger = tracedLogger trace (const (pure ())) (pure ())
  entries ← withLoggingLifetime logger $ \lifetime →
    managedResourceSmoke lifetime workingReleases smokeWork
  entries `shouldBe` 5
  readMVar trace `shouldReturn`
    [ "write Acquired resource"
    , "write Acquired composite"
    , "write Completed bounded work"
    , "write Released resource"
    , "write Released resource"
    , "write Released resource"
    , "write Resource smoke completed"
    , "flush"
    ]

testManagedSmokeReportFails ∷ Expectation
testManagedSmokeReportFails = do
  trace ← newMVar []
  slot ← newEmptyMVar
  let logger = tracedLogger trace failOnError (pure ())
  propagated ←
    expectFailure $ withLoggingLifetime logger $ \lifetime → do
      putMVar slot lifetime
      managedResourceSmoke lifetime workingReleases (\_ _ → throwIO workFailure)
  -- The original failure still propagates, reported once.
  (fromException propagated ∷ Maybe ErrorCall) `shouldBe` Just workFailure
  terminalReportAttempted propagated `shouldBe` True
  -- The failed report reached the lifetime owner, on the handle and on the
  -- failure, and nothing was flushed through the sink that failed.
  lifetime ← readMVar slot
  recorded ← recordedReports lifetime
  attemptMessages [failure | ReportFailed failure ← recorded] `shouldBe` [Just "sink unavailable"]
  attemptMessages (failedReports propagated) `shouldBe` [Just "sink unavailable"]
  readMVar trace `shouldReturn`
    [ "write Acquired resource"
    , "write Acquired composite"
    , "write Resource smoke abandoned"
    ]
