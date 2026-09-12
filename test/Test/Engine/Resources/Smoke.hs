-- | Examples for 'Hetoimasia.Runtime.Resources.resourceSmoke', the console
-- application's owned-resource demonstration.
--
-- The executable runs that body with working releases and the module's own
-- bounded work; these examples run the same body with a failure injected into
-- one of the three places a real run can fail — the work, a release, or the
-- sink a lifecycle record is written to — and assert what a caller sees.
--
-- Everything asserted here is public: the exception that propagated, the
-- evidence 'cleanupFailures' reads out of it, the records that reached an
-- injected sink, and the order the injected release outcomes ran in. Nothing
-- reaches into the demonstration's internals.
--
-- Concurrency is coordinated with 'MVar's, never with a sleep; 'boundedExample'
-- only stops an example that has already hung.
module Test.Engine.Resources.Smoke (spec) where

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
  , ErrorCall (ErrorCall)
  , IOException
  , SomeException
  , bracket
  , fromException
  , someExceptionContext
  , throwIO
  , try
  )
import Control.Exception.Context (getExceptionAnnotations)
import Control.Monad (when)
import qualified Data.Map.Strict as Map
import Data.Maybe (mapMaybe)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.IO as TextIO
import Hetoimasia.Foundation.Log
  ( LogEntry (..)
  , LogLevel (..)
  , LogSink
  , Logger
  , callbackSink
  , componentText
  , defaultLogFilter
  , handleLogger
  , mkLogger
  )
import Hetoimasia.Foundation.Resource
  ( CleanupFailure
  , cleanupFailureLabel
  , cleanupFailures
  )
import Hetoimasia.Runtime.Resources
  ( DiagnosticFailure (..)
  , ReleaseOutcomes (..)
  , SmokeWork
  , resourceSmoke
  , smokeWork
  )
import System.FilePath ((</>))
import System.IO
  ( BufferMode (LineBuffering)
  , IOMode (WriteMode)
  , hClose
  , hGetBuffering
  , hIsOpen
  , hSetBuffering
  , openFile
  )
import System.IO.Error (ioeGetErrorString)
import System.IO.Temp (withSystemTempDirectory)
import System.Timeout (timeout)
import Test.Hspec
  ( Expectation
  , Spec
  , describe
  , expectationFailure
  , it
  , shouldBe
  , shouldContain
  , shouldReturn
  )

spec ∷ Spec
spec = describe "Console resource smoke" $ do
  describe "Injected failures" $ do
    it "releases everything and reports once when the injected work fails"
      testWorkFailure
    it "propagates a release failure with its evidence and reports it once"
      testReleaseFailure
    it "keeps the work's failure and the ordered evidence when the report also fails"
      testCombinedFailures
    it "releases everything and reports nothing when a lifecycle record's sink fails"
      testLifecycleSinkFailure
    it "reports a work failure through a sink that only the lifecycle records broke"
      testWorkFailureAfterLifecycleSinkRecovers
    it "propagates cancellation delivered to the work, unreported"
      (boundedExample testCancelledDuringWork)
    it "propagates cancellation delivered while the report blocks"
      (boundedExample testCancelledWhileReporting)

  describe "Sink disposal" $ do
    it "writes every cleanup record before the test closes the handle it owns"
      testCleanupBeforeSinkDisposal

-- Fixtures --------------------------------------------------------------------

-- | The injected work's own failure, distinguishable from any release or sink
-- failure by both its type and its payload.
workFailure ∷ ErrorCall
workFailure = ErrorCall "resource smoke work exploded"

-- | The releases, in the order the demonstration attempts them: the composite's
-- parts in its declared order, then the enclosing scope's own allocation.
attemptedReleases ∷ [Text]
attemptedReleases = ["channel.buffer", "channel.store", "workspace"]

-- | Release outcomes that record every attempt, so an example can see which
-- releases ran whatever else failed.
--
-- Each action is bounded and non-blocking, as an action running inside an
-- uninterruptible release must be.
observedReleases ∷ MVar [Text] → ReleaseOutcomes
observedReleases attempts = ReleaseOutcomes
  { onReleaseWorkspace = note attempts "workspace"
  , onReleaseBuffer = note attempts "channel.buffer"
  , onReleaseStore = note attempts "channel.store"
  }

-- | Record the attempt first, then fail: evidence must show every release that
-- was attempted, not only those that succeeded.
failingRelease ∷ MVar [Text] → Text → String → IO ()
failingRelease attempts name message = do
  note attempts name
  ioError (userError message)

note ∷ MVar [Text] → Text → IO ()
note slot entry = modifyMVar_ slot (pure . (<> [entry]))

-- | A sink collecting entries in emission order.
newCollector ∷ IO (LogSink, IO [LogEntry])
newCollector = do
  collected ← newMVar []
  let sink entry = modifyMVar_ collected (pure . (entry :))
  pure (callbackSink sink, reverse <$> readMVar collected)

-- | A sink that accepts the first @limit@ records and fails on every one after
-- them, reporting how many records it was handed in total.
newFailingAfter ∷ Int → IO (LogSink, IO [LogEntry], IO Int)
newFailingAfter limit = do
  collected ← newMVar []
  let sink entry = do
        seen ← modifyMVar collected $ \entries →
          let kept = entry : entries in pure (kept, length kept)
        when (seen > limit) (ioError (userError "sink unavailable"))
  pure
    ( callbackSink sink
    , reverse <$> readMVar collected
    , length <$> readMVar collected
    )

-- | A sink that accepts diagnostics below 'Error' and fails on an 'Error',
-- which is the one level the reporting boundary uses.
newReportFailingSink ∷ IO (LogSink, IO [LogEntry])
newReportFailingSink = do
  collected ← newMVar []
  let sink entry = do
        modifyMVar_ collected (pure . (entry :))
        when (entryLevel entry == Error) (ioError (userError "sink unavailable"))
  pure (callbackSink sink, reverse <$> readMVar collected)

-- | Run the demonstration on its own thread and publish its outcome, then kill
-- that thread once @entered@ proves it has parked at an interruptible point.
-- The gate is the coordination: nothing here sleeps.
cancelledSmokeOutcome
  ∷ Logger → ReleaseOutcomes → SmokeWork → MVar () → IO (Either SomeException Int)
cancelledSmokeOutcome logger outcomes work entered = do
  outcome ← newEmptyMVar
  runner ← forkIO $ try (resourceSmoke logger outcomes work) >>= putMVar outcome
  takeMVar entered
  killThread runner
  takeMVar outcome

-- | Signals that it has arrived, then blocks on an 'MVar' the example holds and
-- never fills. That retained reference is what makes this an interruptible
-- block rather than a deadlock the runtime would report as an ordinary failure.
blockedAt ∷ MVar () → MVar () → IO a
blockedAt entered held = do
  putMVar entered ()
  takeMVar held
  throwIO (ErrorCall "a blocked action was released")

-- | The cancellation escaped as itself, rather than as success or as some
-- earlier exception the boundary had in hand.
cancelled ∷ Either SomeException Int → Expectation
cancelled (Right _) = expectationFailure "the cancelled run reported success"
cancelled (Left failure) =
  (fromException failure ∷ Maybe AsyncException) `shouldBe` Just ThreadKilled

-- | Require the run to fail, and return what propagated with its context.
expectFailure ∷ IO Int → IO SomeException
expectFailure action = do
  outcome ← try action
  case outcome of
    Left failure → pure failure
    Right _ → fail "expected the resource smoke to fail, but it returned"

summaries ∷ [LogEntry] → [(LogLevel, Text, Text)]
summaries = map summary
  where
    summary entry =
      (entryLevel entry, componentText (entryComponent entry), entryMessage entry)

-- | The two acquisition records every run emits before its work begins.
acquisitions ∷ [(LogLevel, Text, Text)]
acquisitions =
  [ (Info, "runtime.resources", "Acquired resource")
  , (Info, "runtime.resources", "Acquired composite")
  ]

abandoned ∷ (LogLevel, Text, Text)
abandoned = (Error, "runtime.resources", "Resource smoke abandoned")

-- | One field of the single report, so an example can assert what the boundary
-- put in it.
reportField ∷ Text → [LogEntry] → [Text]
reportField key entries =
  [value | entry ← entries, entryLevel entry == Error, Just value ← [Map.lookup key (entryFields entry)]]

labelsOf ∷ [CleanupFailure] → [Text]
labelsOf = map cleanupFailureLabel

boundedExample ∷ Expectation → Expectation
boundedExample action = do
  finished ← timeout exampleBoundMicroseconds action
  case finished of
    Just () → pure ()
    Nothing → expectationFailure "the example did not finish within its bound"

exampleBoundMicroseconds ∷ Int
exampleBoundMicroseconds = 30 * 1000 * 1000

-- Injected failures -----------------------------------------------------------

testWorkFailure ∷ Expectation
testWorkFailure = do
  (sink, collected) ← newCollector
  attempts ← newMVar []
  let logger = mkLogger defaultLogFilter sink
  propagated ←
    expectFailure (resourceSmoke logger (observedReleases attempts) (\_ _ → throwIO workFailure))
  -- The work's exception, with its payload, reaches the caller unchanged.
  (fromException propagated ∷ Maybe ErrorCall) `shouldBe` Just workFailure
  -- Every acquired resource was still released, in the demonstration's order.
  readMVar attempts `shouldReturn` attemptedReleases
  entries ← collected
  -- Exactly one report, and no completion record for a run that threw.
  summaries entries `shouldBe` acquisitions <> [abandoned]
  reportField "released" entries `shouldBe` [Text.intercalate "," attemptedReleases]
  reportField "cleanup.failures" entries `shouldBe` ["0"]

testReleaseFailure ∷ Expectation
testReleaseFailure = do
  (sink, collected) ← newCollector
  attempts ← newMVar []
  let logger = mkLogger defaultLogFilter sink
      outcomes =
        (observedReleases attempts)
          { onReleaseStore = failingRelease attempts "channel.store" "store release failed"
          }
  propagated ← expectFailure (resourceSmoke logger outcomes smokeWork)
  -- The work succeeded, so the release's own exception is primary.
  (ioeGetErrorString <$> (fromException propagated ∷ Maybe IOException))
    `shouldBe` Just "store release failed"
  labelsOf (cleanupFailures propagated) `shouldBe` ["channel store"]
  -- A failing release never skips the releases after it.
  readMVar attempts `shouldReturn` attemptedReleases
  entries ← collected
  summaries entries
    `shouldBe` acquisitions
      <> [(Info, "runtime.resources", "Completed bounded work"), abandoned]
  reportField "cleanup.labels" entries `shouldBe` ["channel store"]

testCombinedFailures ∷ Expectation
testCombinedFailures = do
  (sink, collected) ← newReportFailingSink
  attempts ← newMVar []
  let logger = mkLogger defaultLogFilter sink
      outcomes = ReleaseOutcomes
        { onReleaseWorkspace = note attempts "workspace"
        , onReleaseBuffer =
            failingRelease attempts "channel.buffer" "buffer release failed"
        , onReleaseStore =
            failingRelease attempts "channel.store" "store release failed"
        }
  propagated ←
    expectFailure (resourceSmoke logger outcomes (\_ _ → throwIO workFailure))
  -- The work's failure stays primary through two cleanup failures and a failed
  -- report: its type, its payload, and its retained evidence all survive.
  (fromException propagated ∷ Maybe ErrorCall) `shouldBe` Just workFailure
  let retained = cleanupFailures propagated
  labelsOf retained `shouldBe` ["channel buffer", "channel store"]
  readMVar attempts `shouldReturn` attemptedReleases
  entries ← collected
  -- One reporting attempt, and never a second one through the sink that just
  -- failed.
  summaries entries `shouldBe` acquisitions <> [abandoned]
  reportField "cleanup.labels" entries
    `shouldBe` ["channel buffer,channel store"]
  reportField "cleanup.failures" entries `shouldBe` ["2"]

testLifecycleSinkFailure ∷ Expectation
testLifecycleSinkFailure = do
  -- The first acquisition record is accepted and the second fails, so the
  -- failure arrives with both resources acquired and neither yet released.
  (sink, collected, handed) ← newFailingAfter 1
  attempts ← newMVar []
  let logger = mkLogger defaultLogFilter sink
  propagated ← expectFailure (resourceSmoke logger (observedReleases attempts) smokeWork)
  (ioeGetErrorString <$> (fromException propagated ∷ Maybe IOException))
    `shouldBe` Just "sink unavailable"
  -- A failed diagnostic never skips a destruction.
  readMVar attempts `shouldReturn` attemptedReleases
  entries ← collected
  -- A resource failure is worth a report; a diagnostic's own failure is not.
  -- The sink that just failed is the only one there is, so nothing is written
  -- back through it and no completion is claimed either.
  summaries entries `shouldBe` acquisitions
  -- Exactly two records were handed to the sink: the accepted acquisition and
  -- the one that failed. There was no third, reporting attempt.
  handed `shouldReturn` 2
  -- The boundary recognized it as a diagnostic failure rather than guessing
  -- from the exception's type, which a release failure shares.
  (getExceptionAnnotations (someExceptionContext propagated) ∷ [DiagnosticFailure])
    `shouldBe` [DiagnosticFailure]

testWorkFailureAfterLifecycleSinkRecovers ∷ Expectation
testWorkFailureAfterLifecycleSinkRecovers = do
  -- The same sink exception, raised by the work rather than by a lifecycle
  -- record: this one is an ordinary failure and does get its one report.
  (sink, collected) ← newCollector
  attempts ← newMVar []
  let logger = mkLogger defaultLogFilter sink
      work _ _ = ioError (userError "sink unavailable")
  propagated ← expectFailure (resourceSmoke logger (observedReleases attempts) work)
  (ioeGetErrorString <$> (fromException propagated ∷ Maybe IOException))
    `shouldBe` Just "sink unavailable"
  (getExceptionAnnotations (someExceptionContext propagated) ∷ [DiagnosticFailure])
    `shouldBe` []
  readMVar attempts `shouldReturn` attemptedReleases
  entries ← collected
  summaries entries `shouldBe` acquisitions <> [abandoned]

testCancelledDuringWork ∷ Expectation
testCancelledDuringWork = do
  (sink, collected) ← newCollector
  attempts ← newMVar []
  entered ← newEmptyMVar
  held ← newEmptyMVar
  let logger = mkLogger defaultLogFilter sink
  outcome ←
    cancelledSmokeOutcome
      logger
      (observedReleases attempts)
      (\_ _ → blockedAt entered held)
      entered
  cancelled outcome
  -- Cancellation does not skip cleanup.
  readMVar attempts `shouldReturn` attemptedReleases
  entries ← collected
  -- Reported nowhere: no Error, and no completion either.
  summaries entries `shouldBe` acquisitions

testCancelledWhileReporting ∷ Expectation
testCancelledWhileReporting = do
  attempts ← newMVar []
  entered ← newEmptyMVar
  held ← newEmptyMVar
  let sink entry =
        when (entryLevel entry == Error) (blockedAt entered held)
      logger = mkLogger defaultLogFilter (callbackSink sink)
  -- The work fails synchronously first, so a boundary that let that earlier
  -- exception win would surface ErrorCall here instead of ThreadKilled.
  outcome ←
    cancelledSmokeOutcome
      logger
      (observedReleases attempts)
      (\_ _ → throwIO workFailure)
      entered
  cancelled outcome
  readMVar attempts `shouldReturn` attemptedReleases

-- Sink disposal ---------------------------------------------------------------

testCleanupBeforeSinkDisposal ∷ Expectation
testCleanupBeforeSinkDisposal =
  withSystemTempDirectory "hetoimasia-resource-smoke" $ \directory → do
    let path = directory </> "records.log"
    attempts ← newMVar []
    (unwound, buffering, openBeforeClose) ←
      bracket (openFile path WriteMode) closeIfOpen $ \handle → do
        hSetBuffering handle LineBuffering
        logger ← handleLogger defaultLogFilter handle
        entries ← resourceSmoke logger (observedReleases attempts) smokeWork
        entries `shouldBe` 5
        -- The scope has already unwound: every release ran before this line,
        -- and the handle is still the test's to close.
        released ← readMVar attempts
        open ← hIsOpen handle
        mode ← hGetBuffering handle
        hClose handle
        pure (released, mode, open)
    unwound `shouldBe` attemptedReleases
    -- The sink borrowed the handle: it neither closed it nor rebuffered it.
    openBeforeClose `shouldBe` True
    show buffering `shouldBe` show LineBuffering
    recorded ← Text.lines <$> TextIO.readFile path
    -- Every cleanup record reached the file, and the completion record follows
    -- them: the scope had unwound before anything was written here, and the
    -- handle was closed only afterwards.
    map recordMessage recorded
      `shouldContain` [ "Released resource"
                      , "Released resource"
                      , "Released resource"
                      , "Resource smoke completed"
                      ]
    -- Every cleanup record names the resource it released.
    mapMaybe releasedResource recorded `shouldBe` attemptedReleases
  where
    closeIfOpen handle = hIsOpen handle >>= \open → when open (hClose handle)

-- | The message of one rendered record, which the layout quotes after @msg=@.
recordMessage ∷ Text → Text
recordMessage line = case Text.breakOn marker line of
  (_, rest)
    | Text.null rest → line
    | otherwise → Text.takeWhile (/= '"') (Text.drop (Text.length marker) rest)
  where
    marker = "msg=\""

-- | The @resource=@ value of a rendered release record, if this line is one.
releasedResource ∷ Text → Maybe Text
releasedResource line
  | recordMessage line /= "Released resource" = Nothing
  | otherwise =
      case [ Text.drop (Text.length marker) segment
           | segment ← Text.words line
           , marker `Text.isPrefixOf` segment
           ] of
        (value : _) → Just value
        [] → Nothing
  where
    marker = "resource="
