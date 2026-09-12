-- | Examples for 'Hetoimasia.Foundation.Resource'.
--
-- The scope's whole contract is observable through its public API, so every
-- example below drives 'withResource' or 'withResourceLabelled' and inspects
-- what a caller can see: the value returned, the exception that propagated,
-- and the cleanup failures 'cleanupFailures' reports.
--
-- Concurrency is coordinated with 'MVar's and with 'threadStatus', never with
-- a sleep. 'boundedExample' only stops an example that has already hung.
module Test.Engine.Resources.Spec (spec) where

import Control.Concurrent (ThreadId, forkIO, killThread, throwTo, yield)
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
  , SomeException
  , WhileHandling (WhileHandling)
  , annotateIO
  , catch
  , fromException
  , rethrowIO
  , someExceptionContext
  , throwIO
  , toException
  , try
  , tryWithContext
  )
import Control.Exception.Annotation (ExceptionAnnotation)
import Control.Exception.Context (ExceptionContext, getExceptionAnnotations)
import Control.Monad (void)
import Data.Text (Text)
import GHC.Conc (BlockReason (BlockedOnException), ThreadStatus (..), threadStatus)
import Hetoimasia.Foundation.Resource
  ( CleanupFailure
  , cleanupFailureException
  , cleanupFailureLabel
  , cleanupFailures
  , cleanupFailuresInContext
  , displayCleanupFailure
  , withResource
  , withResourceLabelled
  )
import System.IO
  ( Handle
  , IOMode (WriteMode)
  , hClose
  , hIsOpen
  , hPutStrLn
  , openFile
  )
import System.IO.Error (ioeGetErrorString)
import System.IO.Temp (withSystemTempDirectory)
import System.FilePath ((</>))
import System.Timeout (timeout)
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
spec = describe "Resources" $ do
  describe "Resource scope outcomes" $ do
    it "returns the body's result when the body and the release both succeed"
      testBothSucceed
    it "propagates the body's failure unchanged when the release succeeds"
      testBodyFailsCleanupSucceeds
    it "propagates a cancellation recognizable by a typed catch"
      (boundedExample testCancellationPropagates)
    it "fails with the release's exception and discards the result when only the release fails"
      testCleanupOnlyFailure
    it "propagates the body's failure and retains the release failure when both fail"
      testBothFail
    it "propagates a failed acquisition and runs no release"
      testAcquisitionFails

  describe "Resource scope nesting" $ do
    it "retains nested cleanup failures in the order they were observed"
      testNestedOrder
    it "keeps two cleanup failures that render identically distinct"
      testEqualMessagesStayDistinct
    it "retains the first cleanup exception once when only the releases fail"
      testNestedCleanupOnlyFailure
    it "attempts each registered release exactly once per scope exit"
      testEachReleaseAttemptedOnce
    it "surfaces evidence a release carried out of its own scope"
      testEvidenceFromInsideRelease

  describe "Resource scope mask discipline" $ do
    it "cancels an acquisition blocked on an MVar and runs no release"
      (boundedExample testAcquisitionCancellable)
    it "runs the release for a cancellation delivered after acquisition"
      (boundedExample testCancellationAfterAcquisition)
    it "restores the caller's masking state after an inner scope completes normally"
      (boundedExample testMaskingRestoredAfterInnerScope)
    it "defers an asynchronous exception aimed at a release until that unwind's releases finish"
      (boundedExample testDeferredDeliveryDuringRelease)
    it "retains an exception a release raises and still attempts the remaining releases"
      testReleaseRaisedAsyncTypeIsCleanupFailure

  describe "Resource scope evidence retention" $ do
    it "keeps an annotation from inside the scope reachable when the release succeeds"
      testContextThroughSuccessfulCleanup
    it "keeps an annotation from inside the scope reachable when the release also fails"
      testContextThroughCombinedFailure
    it "keeps an annotation from inside the release reachable above the scope"
      testContextThroughCleanupOnlyFailure
    it "recognizes the original exception type through a context-aware typed catch"
      testTypedContextAwareCatch
    it "finds evidence through a caller's plain catch and rethrow"
      testEvidenceThroughWhileHandling
    it "reports evidence reached by two routes exactly once"
      testEvidenceReachedTwiceReportedOnce
    it "loses evidence through a bare typed try"
      testBareTypedTryLosesEvidence
    it "loses evidence through a try followed by a plain throwIO"
      testTryThenThrowIOLosesEvidence

  describe "Resource scope owned handles" $ do
    it "closes a temporary file handle the scope owns"
      testOwnedTemporaryHandle

-- Fixtures -------------------------------------------------------------------

-- | A caller's own annotation, used to prove that an annotation attached below
-- a scope is still directly reachable above it.
newtype Marker = Marker String
  deriving (Eq, Show)

instance ExceptionAnnotation Marker

-- | An ordered log of the releases an example observed.
newtype Trail = Trail (MVar [Text])

newTrail ∷ IO Trail
newTrail = Trail <$> newMVar []

record ∷ Trail → Text → IO ()
record (Trail slot) entry = modifyMVar_ slot (pure . (<> [entry]))

trail ∷ Trail → IO [Text]
trail (Trail slot) = readMVar slot

-- | Run @action@, requiring it to fail, and return what propagated.
expectFailure ∷ IO a → IO SomeException
expectFailure action = do
  outcome ← try action
  case outcome of
    Left exception → pure exception
    Right _ → fail "expected the scope to fail, but it returned"

errorCallMessage ∷ SomeException → Maybe String
errorCallMessage exception = case fromException exception of
  Just (ErrorCall message) → Just message
  Nothing → Nothing

ioErrorMessage ∷ SomeException → Maybe String
ioErrorMessage exception = case fromException exception of
  Just failure → Just (ioeGetErrorString (failure ∷ IOException))
  Nothing → Nothing

asyncException ∷ SomeException → Maybe AsyncException
asyncException = fromException

-- | The exception a cleanup failure retained, without its context.
failureException ∷ CleanupFailure → SomeException
failureException failure = case cleanupFailureException failure of
  ExceptionWithContext _ exception → exception

-- | The context that exception carried when the scope caught it.
failureContext ∷ CleanupFailure → ExceptionContext
failureContext failure = case cleanupFailureException failure of
  ExceptionWithContext context _ → context

labelsOf ∷ [CleanupFailure] → [Text]
labelsOf = map cleanupFailureLabel

ioMessagesOf ∷ [CleanupFailure] → [Maybe String]
ioMessagesOf = map (ioErrorMessage . failureException)

markersIn ∷ ExceptionContext → [Marker]
markersIn = getExceptionAnnotations

-- | The cleanup failures attached directly to one context, without following
-- any nesting below it.
directFailures ∷ ExceptionContext → [CleanupFailure]
directFailures = getExceptionAnnotations

-- | The exceptions a caller's handler annotations left below one context.
handledBelow ∷ ExceptionContext → [SomeException]
handledBelow context =
  [handled | WhileHandling handled ← getExceptionAnnotations context]

handledFailures ∷ SomeException → [CleanupFailure]
handledFailures = directFailures . someExceptionContext

-- | Stop an example that has hung rather than letting the suite wait forever.
-- No example depends on this bound for its result.
boundedExample ∷ Expectation → Expectation
boundedExample action = do
  finished ← timeout exampleBoundMicroseconds action
  case finished of
    Just () → pure ()
    Nothing → expectationFailure "the example did not finish within its bound"

exampleBoundMicroseconds ∷ Int
exampleBoundMicroseconds = 30 * 1000 * 1000

-- | Wait until @target@ has stopped making progress towards its 'throwTo',
-- so an example knows a cancellation is pending without guessing at a delay.
-- The status it settled on is returned, so an example can assert that the
-- cancellation really was still undelivered.
awaitPendingThrow ∷ ThreadId → IO ThreadStatus
awaitPendingThrow target = do
  status ← threadStatus target
  case status of
    ThreadBlocked BlockedOnException → pure status
    ThreadFinished → pure status
    ThreadDied → pure status
    _ → yield *> awaitPendingThrow target

-- Outcomes -------------------------------------------------------------------

testBothSucceed ∷ Expectation
testBothSucceed = do
  releases ← newTrail
  result ←
    withResource
      (pure (7 ∷ Int))
      (\_ → record releases "release")
      (\value → pure (value * 2))
  result `shouldBe` 14
  trail releases `shouldReturn` ["release"]

testBodyFailsCleanupSucceeds ∷ Expectation
testBodyFailsCleanupSucceeds = do
  releases ← newTrail
  propagated ←
    expectFailure $
      withResource
        (pure ())
        (\_ → record releases "release")
        (\_ → throwIO (ErrorCall "body failed"))
  errorCallMessage propagated `shouldBe` Just "body failed"
  -- Successful cleanup is never reported for a body that threw.
  length (cleanupFailures propagated) `shouldBe` 0
  trail releases `shouldReturn` ["release"]

testCancellationPropagates ∷ Expectation
testCancellationPropagates = do
  releases ← newTrail
  entered ← newEmptyMVar
  blocker ← newEmptyMVar
  outcome ← newEmptyMVar
  runner ← forkIO $ do
    captured ←
      try $
        withResource
          (pure ())
          (\_ → record releases "release")
          (\_ → putMVar entered () *> takeMVar blocker)
    putMVar outcome (captured ∷ Either SomeException ())
  takeMVar entered
  killThread runner
  captured ← takeMVar outcome
  case captured of
    Right () → expectationFailure "expected the cancellation to propagate"
    Left propagated → do
      asyncException propagated `shouldBe` Just ThreadKilled
      trail releases `shouldReturn` ["release"]

testCleanupOnlyFailure ∷ Expectation
testCleanupOnlyFailure = do
  bodies ← newTrail
  propagated ←
    expectFailure $
      withResourceLabelled
        "only"
        (pure ())
        (\_ → throwIO (userError "release failed"))
        (\_ → record bodies "body" *> pure (1 ∷ Int))
  -- The body ran and returned, and its result was discarded.
  trail bodies `shouldReturn` ["body"]
  ioErrorMessage propagated `shouldBe` Just "release failed"
  -- The primary exception is itself retained as one labelled entry.
  let retained = cleanupFailures propagated
  labelsOf retained `shouldBe` ["only"]
  ioMessagesOf retained `shouldBe` [Just "release failed"]

testBothFail ∷ Expectation
testBothFail = do
  propagated ←
    expectFailure $
      withResourceLabelled
        "both"
        (pure ())
        (\_ → throwIO (userError "release failed"))
        (\_ → throwIO (ErrorCall "body failed"))
  errorCallMessage propagated `shouldBe` Just "body failed"
  let retained = cleanupFailures propagated
  labelsOf retained `shouldBe` ["both"]
  ioMessagesOf retained `shouldBe` [Just "release failed"]

testAcquisitionFails ∷ Expectation
testAcquisitionFails = do
  releases ← newTrail
  bodies ← newTrail
  propagated ←
    expectFailure $
      withResource
        (throwIO (ErrorCall "acquisition failed") ∷ IO ())
        (\_ → record releases "release")
        (\_ → record bodies "body")
  errorCallMessage propagated `shouldBe` Just "acquisition failed"
  length (cleanupFailures propagated) `shouldBe` 0
  trail releases `shouldReturn` []
  trail bodies `shouldReturn` []

-- Nesting --------------------------------------------------------------------

testNestedOrder ∷ Expectation
testNestedOrder = do
  propagated ←
    expectFailure $
      withResourceLabelled "outer" (pure ()) (\_ → throwIO (userError "outer released")) $ \_ →
        withResourceLabelled "inner" (pure ()) (\_ → throwIO (userError "inner released")) $ \_ →
          throwIO (ErrorCall "body failed")
  errorCallMessage propagated `shouldBe` Just "body failed"
  let retained = cleanupFailures propagated
  labelsOf retained `shouldBe` ["inner", "outer"]
  ioMessagesOf retained `shouldBe` [Just "inner released", Just "outer released"]

testEqualMessagesStayDistinct ∷ Expectation
testEqualMessagesStayDistinct = do
  propagated ←
    expectFailure $
      withResourceLabelled "same" (pure ()) (\_ → throwIO (userError "released")) $ \_ →
        withResourceLabelled "same" (pure ()) (\_ → throwIO (userError "released")) $ \_ →
          throwIO (ErrorCall "body failed")
  let retained = cleanupFailures propagated
  length retained `shouldBe` 2
  ioMessagesOf retained `shouldBe` [Just "released", Just "released"]
  map displayCleanupFailure retained
    `shouldBe` replicate 2 "cleanup failed in same: user error (released)"

testNestedCleanupOnlyFailure ∷ Expectation
testNestedCleanupOnlyFailure = do
  propagated ←
    expectFailure $
      withResourceLabelled "outer" (pure ()) (\_ → throwIO (userError "outer released")) $ \_ →
        withResourceLabelled "inner" (pure ()) (\_ → throwIO (userError "inner released")) $ \_ →
          pure (1 ∷ Int)
  -- The inner release's exception is primary, and appears once as evidence.
  ioErrorMessage propagated `shouldBe` Just "inner released"
  let retained = cleanupFailures propagated
  labelsOf retained `shouldBe` ["inner", "outer"]
  ioMessagesOf retained `shouldBe` [Just "inner released", Just "outer released"]

testEachReleaseAttemptedOnce ∷ Expectation
testEachReleaseAttemptedOnce = do
  releases ← newTrail
  propagated ←
    expectFailure $
      withResourceLabelled
        "outer"
        (pure ())
        (\_ → record releases "outer" *> throwIO (userError "outer released"))
        $ \_ →
          withResourceLabelled
            "inner"
            (pure ())
            (\_ → record releases "inner" *> throwIO (userError "inner released"))
            $ \_ → throwIO (ErrorCall "body failed")
  errorCallMessage propagated `shouldBe` Just "body failed"
  -- Each release was attempted once; a throwing release is not retried.
  trail releases `shouldReturn` ["inner", "outer"]
  length (cleanupFailures propagated) `shouldBe` 2

testEvidenceFromInsideRelease ∷ Expectation
testEvidenceFromInsideRelease = do
  propagated ←
    expectFailure $
      withResourceLabelled "outer" (pure ()) outerRelease $ \_ →
        throwIO (ErrorCall "body failed")
  errorCallMessage propagated `shouldBe` Just "body failed"
  let retained = cleanupFailures propagated
  labelsOf retained `shouldBe` ["nested", "outer"]
  ioMessagesOf retained `shouldBe` [Just "nested released", Just "nested released"]
  where
    -- The release opens a scope of its own whose release fails, so the outer
    -- scope's evidence arrives carrying evidence of its own.
    outerRelease _ =
      withResourceLabelled
        "nested"
        (pure ())
        (\_ → throwIO (userError "nested released"))
        (\_ → pure ())

-- Mask discipline ------------------------------------------------------------

testAcquisitionCancellable ∷ Expectation
testAcquisitionCancellable = do
  releases ← newTrail
  bodies ← newTrail
  reached ← newEmptyMVar
  blocker ← newEmptyMVar
  outcome ← newEmptyMVar
  runner ← forkIO $ do
    captured ←
      try $
        withResource
          (putMVar reached () *> takeMVar blocker ∷ IO ())
          (\_ → record releases "release")
          (\_ → record bodies "body")
    putMVar outcome (captured ∷ Either SomeException ())
  takeMVar reached
  killThread runner
  captured ← takeMVar outcome
  case captured of
    Right () → expectationFailure "expected the blocked acquisition to be cancelled"
    Left propagated → do
      asyncException propagated `shouldBe` Just ThreadKilled
      -- No value existed, so no release was invoked.
      trail releases `shouldReturn` []
      trail bodies `shouldReturn` []

testCancellationAfterAcquisition ∷ Expectation
testCancellationAfterAcquisition = do
  releases ← newTrail
  acquired ← newEmptyMVar
  blocker ← newEmptyMVar
  outcome ← newEmptyMVar
  runner ← forkIO $ do
    captured ←
      try $
        withResource
          (pure ())
          (\_ → record releases "release")
          (\_ → putMVar acquired () *> takeMVar blocker)
    putMVar outcome (captured ∷ Either SomeException ())
  takeMVar acquired
  killThread runner
  captured ← takeMVar outcome
  case captured of
    Right () → expectationFailure "expected the cancellation to propagate"
    Left propagated → do
      asyncException propagated `shouldBe` Just ThreadKilled
      trail releases `shouldReturn` ["release"]

-- | An inner scope that completes normally hands control back to an enclosing
-- body running with the caller's masking state, so a cancellation requested
-- there is delivered there, and only the enclosing scope's release is still
-- outstanding.
testMaskingRestoredAfterInnerScope ∷ Expectation
testMaskingRestoredAfterInnerScope = do
  releases ← newTrail
  innerDone ← newEmptyMVar
  blocker ← newEmptyMVar
  outcome ← newEmptyMVar
  runner ← forkIO $ do
    captured ←
      try $
        withResourceLabelled "outer" (pure ()) (\_ → record releases "outer") $ \_ → do
          withResourceLabelled "inner" (pure ()) (\_ → record releases "inner") $ \_ →
            record releases "inner body"
          putMVar innerDone ()
          takeMVar blocker
    putMVar outcome (captured ∷ Either SomeException ())
  takeMVar innerDone
  killThread runner
  captured ← takeMVar outcome
  case captured of
    Right () → expectationFailure "expected the cancellation to propagate"
    Left propagated → do
      asyncException propagated `shouldBe` Just ThreadKilled
      trail releases `shouldReturn` ["inner body", "inner", "outer"]
      -- The inner release had already run, so it is not retried on this unwind.
      length (cleanupFailures propagated) `shouldBe` 0

-- | A cancellation aimed at a thread that is already inside a release waits
-- for that release and for every remaining release of the same unwind.
testDeferredDeliveryDuringRelease ∷ Expectation
testDeferredDeliveryDuringRelease = do
  releases ← newTrail
  insideRelease ← newEmptyMVar
  killerSlot ← newEmptyMVar
  killerStatus ← newEmptyMVar
  killerDone ← newEmptyMVar
  runner ← forkIO $
    void . try @SomeException $
      withResourceLabelled "outer" (pure ()) (\_ → do
        record releases "outer start"
        record releases "outer end")
        $ \_ →
          withResourceLabelled "inner" (pure ()) (\_ → do
            record releases "inner start"
            putMVar insideRelease ()
            killer ← readMVar killerSlot
            status ← awaitPendingThrow killer
            putMVar killerStatus status
            record releases "inner end")
            $ \_ → throwIO (ErrorCall "body failed")
  -- The inner release has started, so the thread is uninterruptibly masked.
  takeMVar insideRelease
  killer ← forkIO (throwTo runner ThreadKilled *> putMVar killerDone ())
  putMVar killerSlot killer
  -- The cancellation was delivered, which cannot happen before cleanup ends.
  takeMVar killerDone
  -- While the release was still running, the sender was still waiting on it.
  observed ← takeMVar killerStatus
  observed `shouldBe` ThreadBlocked BlockedOnException
  trail releases
    `shouldReturn` ["inner start", "inner end", "outer start", "outer end"]

-- | A release that raises an asynchronous-exception type explicitly is a
-- cleanup failure, not an interruption of the masked cleanup.
testReleaseRaisedAsyncTypeIsCleanupFailure ∷ Expectation
testReleaseRaisedAsyncTypeIsCleanupFailure = do
  releases ← newTrail
  propagated ←
    expectFailure $
      withResourceLabelled "outer" (pure ()) (\_ → record releases "outer") $ \_ →
        withResourceLabelled "inner" (pure ()) (\_ → throwIO ThreadKilled) $ \_ →
          throwIO (ErrorCall "body failed")
  -- The body's failure stays primary; the release's ThreadKilled is evidence.
  errorCallMessage propagated `shouldBe` Just "body failed"
  asyncException propagated `shouldBe` Nothing
  let retained = cleanupFailures propagated
  labelsOf retained `shouldBe` ["inner"]
  map (asyncException . failureException) retained `shouldBe` [Just ThreadKilled]
  -- The remaining release was still attempted.
  trail releases `shouldReturn` ["outer"]

-- Evidence retention ---------------------------------------------------------

testContextThroughSuccessfulCleanup ∷ Expectation
testContextThroughSuccessfulCleanup = do
  caught ←
    tryWithContext $
      withResource (pure ()) (\_ → pure ()) $ \_ →
        annotateIO (Marker "inside") (throwIO (ErrorCall "body failed"))
  case caught of
    Right () → expectationFailure "expected the body's failure to propagate"
    Left (ExceptionWithContext context (propagated ∷ SomeException)) → do
      errorCallMessage propagated `shouldBe` Just "body failed"
      markersIn context `shouldBe` [Marker "inside"]

testContextThroughCombinedFailure ∷ Expectation
testContextThroughCombinedFailure = do
  caught ←
    tryWithContext $
      withResourceLabelled "both" (pure ()) (\_ → throwIO (userError "release failed")) $ \_ →
        annotateIO (Marker "inside") (throwIO (ErrorCall "body failed"))
  case caught of
    Right () → expectationFailure "expected the body's failure to propagate"
    Left (ExceptionWithContext context (propagated ∷ SomeException)) → do
      errorCallMessage propagated `shouldBe` Just "body failed"
      markersIn context `shouldBe` [Marker "inside"]
      labelsOf (cleanupFailuresInContext context) `shouldBe` ["both"]

testContextThroughCleanupOnlyFailure ∷ Expectation
testContextThroughCleanupOnlyFailure = do
  caught ←
    tryWithContext $
      withResourceLabelled
        "only"
        (pure ())
        (\_ → annotateIO (Marker "in release") (throwIO (userError "release failed")))
        (\_ → pure (1 ∷ Int))
  case caught of
    Right _ → expectationFailure "expected the release's failure to propagate"
    Left (ExceptionWithContext context (propagated ∷ SomeException)) → do
      ioErrorMessage propagated `shouldBe` Just "release failed"
      markersIn context `shouldBe` [Marker "in release"]
      let retained = cleanupFailuresInContext context
      labelsOf retained `shouldBe` ["only"]
      -- The retained entry keeps the context the exception was caught with.
      map (markersIn . failureContext) retained `shouldBe` [[Marker "in release"]]

testTypedContextAwareCatch ∷ Expectation
testTypedContextAwareCatch = do
  caught ←
    tryWithContext $
      withResourceLabelled "typed" (pure ()) (\_ → throwIO (userError "release failed")) $ \_ →
        annotateIO (Marker "inside") (throwIO (ErrorCall "body failed"))
  case caught of
    Right () → expectationFailure "expected the body's failure to propagate"
    Left (ExceptionWithContext context (ErrorCall message)) → do
      -- A typed catch still recognizes the original type and keeps its context.
      message `shouldBe` "body failed"
      markersIn context `shouldBe` [Marker "inside"]
      labelsOf (cleanupFailuresInContext context) `shouldBe` ["typed"]

testEvidenceThroughWhileHandling ∷ Expectation
testEvidenceThroughWhileHandling = do
  propagated ←
    expectFailure $
      withResourceLabelled "handled" (pure ()) (\_ → throwIO (userError "release failed")) (\_ → throwIO (ErrorCall "body failed"))
        `catch` (\(exception ∷ SomeException) → throwIO exception)
  -- The caller's plain rethrow left nothing directly attached, so the
  -- evidence below is reached only through the handler's annotation.
  length (directFailures (someExceptionContext propagated)) `shouldBe` 0
  let retained = cleanupFailures propagated
  labelsOf retained `shouldBe` ["handled"]
  ioMessagesOf retained `shouldBe` [Just "release failed"]

testEvidenceReachedTwiceReportedOnce ∷ Expectation
testEvidenceReachedTwiceReportedOnce = do
  propagated ←
    expectFailure $
      withResourceLabelled "twice" (pure ()) (\_ → throwIO (userError "release failed")) (\_ → throwIO (ErrorCall "body failed"))
  case cleanupFailures propagated of
    [failure] → do
      -- Attach the same failure both directly and below a handler annotation.
      reachedTwice ←
        expectFailure . annotateIO failure $
          annotateIO failure (throwIO (ErrorCall "inner"))
            `catch` (\(_ ∷ SomeException) → throwIO (ErrorCall "outer"))
      -- The same failure really is reachable on both routes.
      let context = someExceptionContext reachedTwice
      length (directFailures context) `shouldBe` 1
      length (concatMap handledFailures (handledBelow context)) `shouldBe` 1
      -- Inspection still reports it once.
      let retained = cleanupFailures reachedTwice
      length retained `shouldBe` 1
      labelsOf retained `shouldBe` ["twice"]
    other → expectationFailure ("expected one retained failure, got " <> show (length other))

testBareTypedTryLosesEvidence ∷ Expectation
testBareTypedTryLosesEvidence = do
  caught ←
    try $
      withResourceLabelled "bare" (pure ()) (\_ → throwIO (userError "release failed")) (\_ → throwIO (ErrorCall "body failed"))
  case caught of
    Right () → expectationFailure "expected the body's failure to propagate"
    Left bare → do
      -- A bare typed catch keeps the type and value but drops the context.
      case bare of
        ErrorCall message → message `shouldBe` "body failed"
      length (cleanupFailures (toException bare)) `shouldBe` 0
      -- The preserving path keeps the same evidence available.
      preserved ←
        expectFailure $
          withResourceLabelled "bare" (pure ()) (\_ → throwIO (userError "release failed")) (\_ → throwIO (ErrorCall "body failed"))
      labelsOf (cleanupFailures preserved) `shouldBe` ["bare"]

testTryThenThrowIOLosesEvidence ∷ Expectation
testTryThenThrowIOLosesEvidence = do
  propagated ←
    expectFailure $
      withResourceLabelled "rethrown" (pure ()) (\_ → throwIO (userError "release failed")) (\_ → throwIO (ErrorCall "body failed"))
  labelsOf (cleanupFailures propagated) `shouldBe` ["rethrown"]
  -- A plain throwIO on the caught value starts a fresh context.
  lost ← expectFailure (throwIO propagated)
  length (cleanupFailures lost) `shouldBe` 0
  -- rethrowIO with the exception's own context is the preserving path.
  kept ←
    expectFailure
      (rethrowIO (ExceptionWithContext (someExceptionContext propagated) propagated))
  labelsOf (cleanupFailures kept) `shouldBe` ["rethrown"]

-- Owned handles --------------------------------------------------------------

testOwnedTemporaryHandle ∷ Expectation
testOwnedTemporaryHandle = withSystemTempDirectory "hetoimasia-resource" $ \directory → do
  let path = directory </> "owned.txt"
  borrowed ← newEmptyMVar
  written ←
    withResourceLabelled "temporary handle" (openFile path WriteMode) hClose $ \handle → do
      putMVar borrowed handle
      hPutStrLn handle "owned line"
      pure (1 ∷ Int)
  written `shouldBe` 1
  handle ← takeMVar borrowed
  -- The scope closed the handle it owned; the borrowed value is now spent.
  openAfterwards ← hIsOpen (handle ∷ Handle)
  openAfterwards `shouldBe` False
  contents ← readFile path
  contents `shouldBe` "owned line\n"
