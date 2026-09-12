-- | Examples for 'Hetoimasia.Foundation.Resource'.
--
-- The scope's whole contract is observable through its public API, so every
-- example below drives 'withResource', 'withResourceLabelled', 'withComposite',
-- or the continuation facade and inspects what a caller can see: the value
-- returned, the exception that propagated, and the cleanup failures
-- 'cleanupFailures' reports.
--
-- The facade examples keep every borrowed value inside its own scope and
-- return only ordinary results, as the public contract requires. 'withScoped'
-- is run with 'pure' as its continuation only where the scope's result is an
-- ordinary value; a borrowed handle is never returned that way.
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
  , uninterruptibleMask_
  )
import Control.Exception.Annotation (ExceptionAnnotation)
import Control.Exception.Context (ExceptionContext, getExceptionAnnotations)
import Control.Monad (void)
import Control.Monad.IO.Class (liftIO)
import Data.Text (Text)
import GHC.Conc (BlockReason (BlockedOnException), ThreadStatus (..), threadStatus)
import Hetoimasia.Foundation.Resource
  ( Assembly
  , CleanupFailure
  , ReleaseRank
  , acquirePart
  , allocComposite
  , allocResource
  , cleanupFailureException
  , cleanupFailureLabel
  , cleanupFailures
  , cleanupFailuresInContext
  , displayCleanupFailure
  , locally
  , releaseRank
  , restoredStep
  , withComposite
  , withResource
  , withResourceLabelled
  , withScoped
  )
import qualified Test.Engine.Resources.Opacity as Opacity
import qualified Test.Engine.Resources.Smoke as Smoke
import Test.Engine.Resources.Buffer
  ( Buffer (..)
  , Outcomes (..)
  , bufferAssembly
  , bufferLabels
  , deviceTrail
  , newDevice
  , workingDevice
  )
import System.IO
  ( Handle
  , IOMode (WriteMode)
  , hClose
  , hIsOpen
  , hPutStrLn
  , openFile
  )
import System.Directory (doesFileExist)
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

  describe "Composite construction" $ do
    it "releases nothing when the first acquisition fails"
      testFirstAcquisitionFails
    it "releases the part acquired so far when a restored step fails"
      testRestoredStepFails
    it "releases the part acquired so far when the second acquisition fails"
      testSecondAcquisitionFails
    it "releases both parts in the declared order when the binding step fails"
      testBindingStepFails
    it "lends the finished value and releases it in the declared order"
      testCompositeNormalPath
    it "declares an order that is acquisition order for a buffer and its memory"
      testDeclaredOrderIsAcquisitionOrder
    it "declares an order that is not acquisition order when the constructor says so"
      testDeclaredOrderDiffersFromAcquisition
    it "attempts the remaining releases after a rollback release throws"
      testRollbackReleaseThrows
    it "releases each part once and lets no finished value reach the caller"
      testNoDoubleReleaseOrLeakedValue

  describe "Composite part metadata" $ do
    it "releases the parts acquired before a faulting rank and acquires nothing at that stage"
      testRankFaultReleasesAcquiredParts
    it "releases the parts acquired before a faulting label and acquires nothing at that stage"
      testLabelFaultReleasesAcquiredParts
    it "rejects a faulting rank before the later stage that would have failed runs"
      testRankFaultStopsLaterFailingStage
    it "rejects a faulting label before the later stage that would have failed runs"
      testLabelFaultStopsLaterFailingStage
    it "attempts every remaining release after a faulting rank and retains the labelled evidence"
      testRankFaultAttemptsRemainingReleases
    it "attempts every remaining release after a faulting label and retains the labelled evidence"
      testLabelFaultAttemptsRemainingReleases
    it "keeps an enclosing body's failure primary when a faulting rank fails its release"
      testRankFaultUnderEnclosingFailure
    it "keeps an enclosing body's failure primary when a faulting label fails its release"
      testLabelFaultUnderEnclosingFailure
    it "keeps an earlier stage's failure primary and never evaluates a later part's metadata"
      testEarlierFailureStaysPrimaryOverLaterMetadata
    it "closes the handles it owns when a later part's metadata faults"
      testMetadataFaultClosesOwnedHandles

  describe "Composite construction cancellation" $ do
    it "rolls back the parts acquired so far when cancelled in a restored step"
      (boundedExample testCancelledInRestoredStep)
    it "rolls back the parts acquired so far when cancelled inside an acquisition"
      (boundedExample testCancelledInAcquisition)
    it "rolls back a part acquired with a cancellation already pending"
      (boundedExample testCancellationPendingWhenAcquisitionReturns)
    it "defers a cancellation aimed at a rollback until every release has run"
      (boundedExample testCancellationDeferredDuringRollback)

  describe "Composite construction inside a scope" $ do
    it "lets the enclosing scope observe the composite's primary and retained failures"
      testCompositeInsideScope
    it "fails with the first cleanup exception when the final releases fail"
      testFinalReleasesFail
    it "keeps the body's failure primary when the final releases also fail"
      testBodyFailureStaysPrimary

  describe "Continuation facade" $ do
    it "keeps an allocation live in the final callback and releases it when that callback exits"
      testAllocationLiveInFinalCallback
    it "releases a scope's allocations in reverse allocation order on success"
      testFacadeReverseOrderOnSuccess
    it "releases a scope's allocations in reverse allocation order when the scope fails"
      testFacadeReverseOrderOnFailure
    it "releases a scope's allocations in reverse allocation order on cancellation"
      (boundedExample testFacadeReverseOrderOnCancellation)
    it "runs no later acquisition after an earlier action fails"
      testFacadeEarlierFailureStopsAcquisition
    it "runs ordinary actions inside a scope through MonadIO"
      testFacadeMonadIOPath
    it "composes allocations through fmap and <*>"
      testFacadeFunctorApplicative

  describe "Continuation facade agreement with the direct path" $ do
    it "produces the same primary and secondary failures for one resource"
      testDirectAndFacadeAgree
    it "produces the same primary and secondary failures for nested resources"
      testDirectAndFacadeAgreeNested

  describe "Continuation facade nested scopes" $ do
    it "releases everything locally allocated before the outer scope resumes"
      testLocallyReleasesBeforeOuterResumes
    it "carries a locally cleanup failure into the outer scope's evidence"
      testLocallyCleanupFailureReachesOuterScope

  describe "Continuation facade composite allocation" $ do
    it "keeps each composite's declared order while the scope unwinds in reverse"
      testCompositeThroughFacade

  -- The facade's opacity is a property of what the package exports rather than
  -- of a value, so it is asserted by compiling clients outside the package.
  Opacity.spec

  -- The runtime's console demonstration composes these scopes with the logging
  -- contract. Its examples group here, beside the primitives they use.
  Smoke.spec

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

-- Composite construction ------------------------------------------------------

-- | Two parts acquired in that order, released under the ranks the caller
-- declares. Nothing here depends on a graphics API: it exists to show that the
-- release order is a declaration rather than a consequence of acquisition.
pairAssembly ∷ Trail → ReleaseRank → ReleaseRank → Assembly ()
pairAssembly releases firstRank secondRank = do
  acquirePart
    "first"
    firstRank
    (record releases "acquire first")
    (\_ → record releases "first")
  acquirePart
    "second"
    secondRank
    (record releases "acquire second")
    (\_ → record releases "second")

occurrences ∷ Text → [Text] → Int
occurrences entry = length . filter (== entry)

testFirstAcquisitionFails ∷ Expectation
testFirstAcquisitionFails = do
  device ← newDevice
  bodies ← newTrail
  propagated ←
    expectFailure $
      withComposite
        (bufferAssembly device workingDevice {onCreateBuffer = Just "create failed"})
        (\_ → record bodies "body")
  ioErrorMessage propagated `shouldBe` Just "create failed"
  -- Nothing was acquired, so nothing was released and nothing is retained.
  length (cleanupFailures propagated) `shouldBe` 0
  deviceTrail device `shouldReturn` ["create buffer"]
  trail bodies `shouldReturn` []

testRestoredStepFails ∷ Expectation
testRestoredStepFails = do
  device ← newDevice
  bodies ← newTrail
  propagated ←
    expectFailure $
      withComposite
        (bufferAssembly device workingDevice {onQueryRequirements = Just "query failed"})
        (\_ → record bodies "body")
  ioErrorMessage propagated `shouldBe` Just "query failed"
  length (cleanupFailures propagated) `shouldBe` 0
  -- Exactly the one part acquired so far was released.
  deviceTrail device
    `shouldReturn` ["create buffer", "query requirements 1", "destroy buffer 1"]
  trail bodies `shouldReturn` []

testSecondAcquisitionFails ∷ Expectation
testSecondAcquisitionFails = do
  device ← newDevice
  bodies ← newTrail
  propagated ←
    expectFailure $
      withComposite
        (bufferAssembly device workingDevice {onAllocateMemory = Just "allocate failed"})
        (\_ → record bodies "body")
  ioErrorMessage propagated `shouldBe` Just "allocate failed"
  deviceTrail device
    `shouldReturn`
      [ "create buffer"
      , "query requirements 1"
      , "allocate memory 64"
      , "destroy buffer 1"
      ]
  trail bodies `shouldReturn` []

testBindingStepFails ∷ Expectation
testBindingStepFails = do
  device ← newDevice
  bodies ← newTrail
  propagated ←
    expectFailure $
      withComposite
        (bufferAssembly device workingDevice {onBindMemory = Just "bind failed"})
        (\_ → record bodies "body")
  ioErrorMessage propagated `shouldBe` Just "bind failed"
  -- Both parts existed by the binding step, and both were released in the
  -- declared order.
  deviceTrail device
    `shouldReturn`
      [ "create buffer"
      , "query requirements 1"
      , "allocate memory 64"
      , "bind 1 to 2"
      , "destroy buffer 1"
      , "free memory 2"
      ]
  trail bodies `shouldReturn` []

testCompositeNormalPath ∷ Expectation
testCompositeNormalPath = do
  device ← newDevice
  bodies ← newTrail
  observed ←
    withComposite (bufferAssembly device workingDevice) $ \buffer → do
      record bodies "body"
      pure (show (bufferHandle buffer), show (bufferMemory buffer))
  -- The body borrowed a finished value whose parts were bound together.
  observed `shouldBe` ("BufferHandle 1", "MemoryHandle 2")
  trail bodies `shouldReturn` ["body"]
  deviceTrail device
    `shouldReturn`
      [ "create buffer"
      , "query requirements 1"
      , "allocate memory 64"
      , "bind 1 to 2"
      , "destroy buffer 1"
      , "free memory 2"
      ]

testDeclaredOrderIsAcquisitionOrder ∷ Expectation
testDeclaredOrderIsAcquisitionOrder = do
  device ← newDevice
  withComposite (bufferAssembly device workingDevice) (\_ → pure ())
  performed ← deviceTrail device
  let acquisitions = filter (`elem` ["create buffer", "allocate memory 64"]) performed
      releases = filter (`elem` ["destroy buffer 1", "free memory 2"]) performed
  acquisitions `shouldBe` ["create buffer", "allocate memory 64"]
  -- The buffer is created first and destroyed first, so the declared order is
  -- acquisition order. Reversing acquisition would free the memory while the
  -- buffer still referred to it.
  releases `shouldBe` ["destroy buffer 1", "free memory 2"]

testDeclaredOrderDiffersFromAcquisition ∷ Expectation
testDeclaredOrderDiffersFromAcquisition = do
  acquisitionOrder ← newTrail
  withComposite (pairAssembly acquisitionOrder (releaseRank 0) (releaseRank 1)) (\_ → pure ())
  trail acquisitionOrder
    `shouldReturn` ["acquire first", "acquire second", "first", "second"]
  -- The same two stages, in the same acquisition order, with the opposite
  -- release order declared.
  declaredOrder ← newTrail
  withComposite (pairAssembly declaredOrder (releaseRank 1) (releaseRank 0)) (\_ → pure ())
  trail declaredOrder
    `shouldReturn` ["acquire first", "acquire second", "second", "first"]

testRollbackReleaseThrows ∷ Expectation
testRollbackReleaseThrows = do
  device ← newDevice
  bodies ← newTrail
  propagated ←
    expectFailure $
      withComposite
        ( bufferAssembly
            device
            workingDevice
              { onBindMemory = Just "bind failed"
              , onDestroyBuffer = Just "destroy failed"
              }
        )
        (\_ → record bodies "body")
  -- The failure that triggered the rollback stays primary.
  ioErrorMessage propagated `shouldBe` Just "bind failed"
  let retained = cleanupFailures propagated
  labelsOf retained `shouldBe` ["buffer"]
  ioMessagesOf retained `shouldBe` [Just "destroy failed"]
  -- The throwing release did not stop the remaining one from being attempted.
  performed ← deviceTrail device
  occurrences "destroy buffer 1" performed `shouldBe` 1
  occurrences "free memory 2" performed `shouldBe` 1
  trail bodies `shouldReturn` []

testNoDoubleReleaseOrLeakedValue ∷ Expectation
testNoDoubleReleaseOrLeakedValue = do
  device ← newDevice
  escaped ← newTrail
  propagated ←
    expectFailure $
      withComposite
        (bufferAssembly device workingDevice {onBindMemory = Just "bind failed"})
        (\buffer → record escaped "body" *> pure buffer)
  ioErrorMessage propagated `shouldBe` Just "bind failed"
  performed ← deviceTrail device
  occurrences "destroy buffer 1" performed `shouldBe` 1
  occurrences "free memory 2" performed `shouldBe` 1
  -- The body never ran, so no finished value was observable by the caller.
  trail escaped `shouldReturn` []

-- Composite part metadata -----------------------------------------------------

-- A part's label and rank are ordinary arguments to 'acquirePart', so either
-- can be a thunk that throws when it is evaluated — a rank read out of a
-- device table that has no entry for this part, or a label built from a name
-- the caller has not validated. Both are declared beside the acquisition, so
-- both are expected to fault at the same point in the construction, and every
-- example below is written once per faulting field.

-- | The declared rank of the faulting stage's part throws when evaluated.
faultingRank ∷ ReleaseRank
faultingRank = releaseRank (error "rank lookup failed")

-- | The declared label of the faulting stage's part throws when evaluated.
faultingLabel ∷ Text
faultingLabel = error "label lookup failed"

-- | Two parts that acquire and release cleanly, then a third stage carrying
-- the faulting metadata under test.
twoPartsThenFaultingPart ∷ Trail → Text → ReleaseRank → Assembly ()
twoPartsThenFaultingPart releases label rank = do
  acquirePart
    "first"
    (releaseRank 0)
    (record releases "acquire first")
    (\_ → record releases "release first")
  acquirePart
    "second"
    (releaseRank 1)
    (record releases "acquire second")
    (\_ → record releases "release second")
  acquirePart
    label
    rank
    (record releases "acquire third")
    (\_ → record releases "release third")

testRankFaultReleasesAcquiredParts ∷ Expectation
testRankFaultReleasesAcquiredParts =
  metadataFaultReleasesAcquiredParts "third" faultingRank "rank lookup failed"

testLabelFaultReleasesAcquiredParts ∷ Expectation
testLabelFaultReleasesAcquiredParts =
  metadataFaultReleasesAcquiredParts faultingLabel (releaseRank 2) "label lookup failed"

-- | The faulting stage is the only thing that fails: the two parts acquired
-- before it are released once each in the declared order, that stage acquires
-- nothing, and the body never runs.
metadataFaultReleasesAcquiredParts ∷ Text → ReleaseRank → String → Expectation
metadataFaultReleasesAcquiredParts label rank message = do
  releases ← newTrail
  bodies ← newTrail
  propagated ←
    expectFailure $
      withComposite
        (twoPartsThenFaultingPart releases label rank)
        (\_ → record bodies "body")
  errorCallMessage propagated `shouldBe` Just message
  -- The metadata is evaluated before the faulting stage acquires anything, so
  -- that stage owns nothing to release and every earlier part is covered.
  trail releases
    `shouldReturn` ["acquire first", "acquire second", "release first", "release second"]
  -- Every release succeeded, so the metadata fault carries no cleanup evidence.
  length (cleanupFailures propagated) `shouldBe` 0
  trail bodies `shouldReturn` []

testRankFaultStopsLaterFailingStage ∷ Expectation
testRankFaultStopsLaterFailingStage =
  metadataFaultStopsLaterFailingStage "faulting" faultingRank "rank lookup failed"

testLabelFaultStopsLaterFailingStage ∷ Expectation
testLabelFaultStopsLaterFailingStage =
  metadataFaultStopsLaterFailingStage faultingLabel (releaseRank 1) "label lookup failed"

-- | A metadata fault is a construction failure, so the stages after it do not
-- run at all. The binding step below would have failed, and the fault is
-- primary because it was raised first rather than because it displaced
-- anything.
metadataFaultStopsLaterFailingStage ∷ Text → ReleaseRank → String → Expectation
metadataFaultStopsLaterFailingStage label rank message = do
  releases ← newTrail
  bodies ← newTrail
  propagated ←
    expectFailure $
      withComposite
        ( do
            acquirePart
              "first"
              (releaseRank 0)
              (record releases "acquire first")
              (\_ → record releases "release first")
            acquirePart
              label
              rank
              (record releases "acquire faulting")
              (\_ → record releases "release faulting")
            restoredStep (record releases "bind" *> throwIO (userError "binding failure") ∷ IO ())
        )
        (\_ → record bodies "body")
  errorCallMessage propagated `shouldBe` Just message
  ioErrorMessage propagated `shouldBe` Nothing
  -- Neither the faulting stage's acquisition nor the binding step ran, and the
  -- one part acquired before them was released.
  trail releases `shouldReturn` ["acquire first", "release first"]
  length (cleanupFailures propagated) `shouldBe` 0
  trail bodies `shouldReturn` []

testRankFaultAttemptsRemainingReleases ∷ Expectation
testRankFaultAttemptsRemainingReleases =
  metadataFaultAttemptsRemainingReleases "third" faultingRank "rank lookup failed"

testLabelFaultAttemptsRemainingReleases ∷ Expectation
testLabelFaultAttemptsRemainingReleases =
  metadataFaultAttemptsRemainingReleases faultingLabel (releaseRank 2) "label lookup failed"

-- | A throwing release during the rollback does not stop the remaining one,
-- and the evidence is retained under the acquired part's own valid label. The
-- faulting stage acquired nothing, so it contributes no cleanup entry and no
-- fabricated label.
metadataFaultAttemptsRemainingReleases ∷ Text → ReleaseRank → String → Expectation
metadataFaultAttemptsRemainingReleases label rank message = do
  releases ← newTrail
  propagated ←
    expectFailure $
      withComposite
        ( do
            acquirePart
              "first"
              (releaseRank 0)
              (record releases "acquire first")
              (\_ → record releases "release first" *> throwIO (userError "first release failed"))
            acquirePart
              "second"
              (releaseRank 1)
              (record releases "acquire second")
              (\_ → record releases "release second")
            acquirePart
              label
              rank
              (record releases "acquire third")
              (\_ → record releases "release third")
        )
        (\_ → pure ())
  errorCallMessage propagated `shouldBe` Just message
  let retained = cleanupFailures propagated
  labelsOf retained `shouldBe` ["first"]
  ioMessagesOf retained `shouldBe` [Just "first release failed"]
  trail releases
    `shouldReturn` ["acquire first", "acquire second", "release first", "release second"]

testRankFaultUnderEnclosingFailure ∷ Expectation
testRankFaultUnderEnclosingFailure =
  metadataFaultUnderEnclosingFailure "second" faultingRank "rank lookup failed"

testLabelFaultUnderEnclosingFailure ∷ Expectation
testLabelFaultUnderEnclosingFailure =
  metadataFaultUnderEnclosingFailure faultingLabel (releaseRank 1) "label lookup failed"

-- | A failure that is already being unwound stays primary when a metadata
-- fault is raised beneath it. The enclosing scope's body fails, its release
-- constructs the faulting composite, and the fault arrives as that scope's
-- cleanup failure with the composite's own labelled evidence still reachable
-- below it.
metadataFaultUnderEnclosingFailure ∷ Text → ReleaseRank → String → Expectation
metadataFaultUnderEnclosingFailure label rank message = do
  releases ← newTrail
  propagated ←
    expectFailure $
      withResourceLabelled
        "outer resource"
        (record releases "acquire outer")
        ( \_ →
            withComposite
              ( do
                  acquirePart
                    "first"
                    (releaseRank 0)
                    (record releases "acquire first")
                    (\_ → record releases "release first" *> throwIO (userError "first release failed"))
                  acquirePart
                    label
                    rank
                    (record releases "acquire second")
                    (\_ → record releases "release second")
              )
              (\_ → pure ())
        )
        (\_ → throwIO (userError "outer body failure"))
  ioErrorMessage propagated `shouldBe` Just "outer body failure"
  let retained = cleanupFailures propagated
  -- The composite's labelled release failure and the enclosing scope's entry
  -- for the metadata fault are both inspectable, in observation order.
  labelsOf retained `shouldBe` ["first", "outer resource"]
  ioMessagesOf retained `shouldBe` [Just "first release failed", Nothing]
  map (errorCallMessage . failureException) retained `shouldBe` [Nothing, Just message]
  trail releases `shouldReturn` ["acquire outer", "acquire first", "release first"]

-- | The stage that fails first is the primary failure. A later part's metadata
-- is never evaluated, because the stage declaring it never runs.
testEarlierFailureStaysPrimaryOverLaterMetadata ∷ Expectation
testEarlierFailureStaysPrimaryOverLaterMetadata = do
  releases ← newTrail
  propagated ←
    expectFailure $
      withComposite
        ( do
            acquirePart
              "first"
              (releaseRank 0)
              (record releases "acquire first")
              (\_ → record releases "release first")
            restoredStep (throwIO (userError "binding failure") ∷ IO ())
            acquirePart
              faultingLabel
              faultingRank
              (record releases "acquire second")
              (\_ → record releases "release second")
        )
        (\_ → pure ())
  ioErrorMessage propagated `shouldBe` Just "binding failure"
  errorCallMessage propagated `shouldBe` Nothing
  trail releases `shouldReturn` ["acquire first", "release first"]

-- | The same fault against handles the composite really owns: both open files
-- are closed when a later part's metadata faults, and the faulting stage never
-- opened its own file.
testMetadataFaultClosesOwnedHandles ∷ Expectation
testMetadataFaultClosesOwnedHandles =
  withSystemTempDirectory "hetoimasia-composite-metadata" $ \directory → do
    let firstPath = directory </> "first.txt"
        secondPath = directory </> "second.txt"
        faultingPath = directory </> "third.txt"
    borrowed ← newEmptyMVar
    propagated ←
      expectFailure $
        withComposite
          ( do
              firstHandle ←
                acquirePart "first handle" (releaseRank 0) (openFile firstPath WriteMode) hClose
              secondHandle ←
                acquirePart "second handle" (releaseRank 1) (openFile secondPath WriteMode) hClose
              restoredStep (putMVar borrowed (firstHandle, secondHandle))
              acquirePart
                faultingLabel
                (releaseRank 2)
                (openFile faultingPath WriteMode)
                hClose
          )
          (\_ → pure ())
    errorCallMessage propagated `shouldBe` Just "label lookup failed"
    (firstHandle, secondHandle) ← takeMVar borrowed
    hIsOpen (firstHandle ∷ Handle) `shouldReturn` False
    hIsOpen (secondHandle ∷ Handle) `shouldReturn` False
    doesFileExist faultingPath `shouldReturn` False

-- Composite construction cancellation -----------------------------------------

testCancelledInRestoredStep ∷ Expectation
testCancelledInRestoredStep = do
  releases ← newTrail
  reached ← newEmptyMVar
  blocker ← newEmptyMVar
  outcome ← newEmptyMVar
  runner ← forkIO $ do
    captured ←
      try $
        withComposite
          ( do
              acquirePart
                "first"
                (releaseRank 0)
                (record releases "acquire first")
                (\_ → record releases "first")
              restoredStep (putMVar reached () *> takeMVar blocker ∷ IO ())
              acquirePart
                "second"
                (releaseRank 1)
                (record releases "acquire second")
                (\_ → record releases "second")
          )
          (\_ → record releases "body")
    putMVar outcome (captured ∷ Either SomeException ())
  takeMVar reached
  killThread runner
  captured ← takeMVar outcome
  case captured of
    Right () → expectationFailure "expected the cancellation to propagate"
    Left propagated → do
      asyncException propagated `shouldBe` Just ThreadKilled
      -- Only the part acquired before the restored step was rolled back.
      trail releases `shouldReturn` ["acquire first", "first"]
      length (cleanupFailures propagated) `shouldBe` 0

testCancelledInAcquisition ∷ Expectation
testCancelledInAcquisition = do
  releases ← newTrail
  reached ← newEmptyMVar
  blocker ← newEmptyMVar
  outcome ← newEmptyMVar
  runner ← forkIO $ do
    captured ←
      try $
        withComposite
          ( do
              acquirePart
                "first"
                (releaseRank 0)
                (record releases "acquire first")
                (\_ → record releases "first")
              acquirePart
                "second"
                (releaseRank 1)
                (putMVar reached () *> takeMVar blocker ∷ IO ())
                (\_ → record releases "second")
          )
          (\_ → record releases "body")
    putMVar outcome (captured ∷ Either SomeException ())
  takeMVar reached
  killThread runner
  captured ← takeMVar outcome
  case captured of
    Right () → expectationFailure "expected the cancellation to propagate"
    Left propagated → do
      asyncException propagated `shouldBe` Just ThreadKilled
      -- The second part was never acquired, so its release never ran, and the
      -- first was not stranded.
      trail releases `shouldReturn` ["acquire first", "first"]

-- | A cancellation aimed at a thread that is already rolling a composite back
-- waits for every release of that rollback, in the declared order.
testCancellationDeferredDuringRollback ∷ Expectation
testCancellationDeferredDuringRollback = do
  releases ← newTrail
  insideRelease ← newEmptyMVar
  killerSlot ← newEmptyMVar
  killerStatus ← newEmptyMVar
  killerDone ← newEmptyMVar
  runner ← forkIO $
    void . try @SomeException $
      withComposite
        ( do
            acquirePart "first" (releaseRank 0) (record releases "acquire first") $ \_ → do
              record releases "first start"
              putMVar insideRelease ()
              killer ← readMVar killerSlot
              status ← awaitPendingThrow killer
              putMVar killerStatus status
              record releases "first end"
            acquirePart
              "second"
              (releaseRank 1)
              (record releases "acquire second")
              (\_ → record releases "second")
            restoredStep (throwIO (ErrorCall "stage failed"))
        )
        (\_ → record releases "body")
  -- The rollback has started, so the thread is uninterruptibly masked.
  takeMVar insideRelease
  killer ← forkIO (throwTo runner ThreadKilled *> putMVar killerDone ())
  putMVar killerSlot killer
  takeMVar killerDone
  observed ← takeMVar killerStatus
  observed `shouldBe` ThreadBlocked BlockedOnException
  trail releases
    `shouldReturn`
      ["acquire first", "acquire second", "first start", "first end", "second"]

-- Composite construction inside a scope ---------------------------------------

testCompositeInsideScope ∷ Expectation
testCompositeInsideScope = do
  device ← newDevice
  releases ← newTrail
  propagated ←
    expectFailure $
      withResourceLabelled
        "outer"
        (pure ())
        (\_ → record releases "outer" *> throwIO (userError "outer released"))
        $ \_ →
          withComposite
            ( bufferAssembly
                device
                workingDevice
                  { onBindMemory = Just "bind failed"
                  , onDestroyBuffer = Just "destroy failed"
                  }
            )
            (\_ → pure ())
  -- The composite's own primary failure reaches the enclosing scope, and the
  -- evidence from both levels arrives in observation order.
  ioErrorMessage propagated `shouldBe` Just "bind failed"
  let retained = cleanupFailures propagated
  labelsOf retained `shouldBe` ["buffer", "outer"]
  ioMessagesOf retained `shouldBe` [Just "destroy failed", Just "outer released"]
  trail releases `shouldReturn` ["outer"]

testFinalReleasesFail ∷ Expectation
testFinalReleasesFail = do
  device ← newDevice
  bodies ← newTrail
  propagated ←
    expectFailure $
      withResourceLabelled "outer" (pure ()) (\_ → pure ()) $ \_ →
        withComposite
          ( bufferAssembly
              device
              workingDevice
                { onDestroyBuffer = Just "destroy failed"
                , onFreeMemory = Just "free failed"
                }
          )
          (\_ → record bodies "body" *> pure (1 ∷ Int))
  trail bodies `shouldReturn` ["body"]
  -- The first cleanup exception becomes the failure and the result is dropped.
  ioErrorMessage propagated `shouldBe` Just "destroy failed"
  let retained = cleanupFailures propagated
  -- Both entries survive the trip through the enclosing scope exactly once.
  labelsOf retained `shouldBe` bufferLabels
  ioMessagesOf retained `shouldBe` [Just "destroy failed", Just "free failed"]
  performed ← deviceTrail device
  occurrences "destroy buffer 1" performed `shouldBe` 1
  occurrences "free memory 2" performed `shouldBe` 1

testBodyFailureStaysPrimary ∷ Expectation
testBodyFailureStaysPrimary = do
  device ← newDevice
  propagated ←
    expectFailure $
      withResourceLabelled "outer" (pure ()) (\_ → pure ()) $ \_ →
        withComposite
          ( bufferAssembly
              device
              workingDevice
                { onDestroyBuffer = Just "destroy failed"
                , onFreeMemory = Just "free failed"
                }
          )
          (\_ → throwIO (ErrorCall "body failed"))
  errorCallMessage propagated `shouldBe` Just "body failed"
  let retained = cleanupFailures propagated
  labelsOf retained `shouldBe` bufferLabels
  ioMessagesOf retained `shouldBe` [Just "destroy failed", Just "free failed"]

-- | A cancellation that is already pending when an acquisition *returns* must
-- not strand the part that acquisition produced.
--
-- The acquisition below masks itself uninterruptibly, waits until the killer's
-- 'throwTo' is blocked on the constructing thread, and only then returns. The
-- pending exception can therefore be delivered no earlier than the next
-- interruptible operation, which is the blocked restored step after
-- 'acquirePart' has installed the rollback — so the part is released.
--
-- This is the case the masked handoff exists for, and it separates that
-- handoff from an implementation that restores the caller's masking state
-- around an acquisition: such an implementation would deliver the moment this
-- acquisition's own mask ended, before any rollback existed, and the part
-- would never be released at all.
testCancellationPendingWhenAcquisitionReturns ∷ Expectation
testCancellationPendingWhenAcquisitionReturns = do
  releases ← newTrail
  bodies ← newTrail
  acquiring ← newEmptyMVar
  killerSlot ← newEmptyMVar
  killerDone ← newEmptyMVar
  neverFilled ← newEmptyMVar
  outcome ← newEmptyMVar
  runner ← forkIO $ do
    captured ←
      try $
        withComposite
          ( do
              acquirePart
                "first"
                (releaseRank 0)
                ( uninterruptibleMask_ $ do
                    record releases "acquire first"
                    putMVar acquiring ()
                    killer ← readMVar killerSlot
                    void (awaitPendingThrow killer)
                )
                (\_ → record releases "first")
              -- The first interruptible operation after the rollback exists.
              restoredStep (takeMVar neverFilled ∷ IO ())
              acquirePart
                "second"
                (releaseRank 1)
                (record releases "acquire second")
                (\_ → record releases "second")
          )
          (\_ → record bodies "body")
    putMVar outcome (captured ∷ Either SomeException ())
  takeMVar acquiring
  killer ← forkIO (throwTo runner ThreadKilled *> putMVar killerDone ())
  putMVar killerSlot killer
  -- The cancellation was delivered, so the construction has unwound.
  takeMVar killerDone
  captured ← takeMVar outcome
  case captured of
    Right () → expectationFailure "expected the cancellation to propagate"
    Left propagated → do
      asyncException propagated `shouldBe` Just ThreadKilled
      performed ← trail releases
      -- The part acquired with the cancellation already pending was rolled
      -- back; no later stage ran, so nothing else was acquired.
      performed `shouldBe` ["acquire first", "first"]
      occurrences "first" performed `shouldBe` 1
      trail bodies `shouldReturn` []
      length (cleanupFailures propagated) `shouldBe` 0

-- Continuation facade -------------------------------------------------------

-- | The cleanup point: a resource allocated in a scope is still live in the
-- final callback, after the @do@ block that allocated it has yielded, and is
-- released when that callback exits rather than at the end of that block.
testAllocationLiveInFinalCallback ∷ Expectation
testAllocationLiveInFinalCallback = do
  steps ← newTrail
  -- The example owns this cell, so it can still read it after the release that
  -- marks the resource closed has run. The scope owns only the marking.
  open ← newMVar True
  liveInCallback ←
    withScoped
      ( do
          resource ←
            allocResource
              (pure open)
              (\slot → modifyMVar_ slot (const (pure False)) *> record steps "release")
          liftIO (record steps "allocated")
          pure resource
      )
      ( \resource → do
          -- The allocating block has yielded and this is the scope's final
          -- callback, so an implementation that released at the end of that
          -- block would have closed the resource before now.
          stillLive ← readMVar resource
          record steps "callback"
          pure stillLive
      )
  liveInCallback `shouldBe` True
  readMVar open `shouldReturn` False
  trail steps `shouldReturn` ["allocated", "callback", "release"]

testFacadeReverseOrderOnSuccess ∷ Expectation
testFacadeReverseOrderOnSuccess = do
  releases ← newTrail
  total ←
    withScoped
      ( do
          first ← allocResource (pure (1 ∷ Int)) (\_ → record releases "first")
          second ← allocResource (pure (2 ∷ Int)) (\_ → record releases "second")
          third ← allocResource (pure (4 ∷ Int)) (\_ → record releases "third")
          pure (first + second + third)
      )
      pure
  total `shouldBe` 7
  trail releases `shouldReturn` ["third", "second", "first"]

testFacadeReverseOrderOnFailure ∷ Expectation
testFacadeReverseOrderOnFailure = do
  releases ← newTrail
  propagated ←
    expectFailure $
      withScoped
        ( do
            _ ← allocResource (pure ()) (\_ → record releases "first")
            _ ← allocResource (pure ()) (\_ → record releases "second")
            liftIO (throwIO (ErrorCall "scope failed") ∷ IO ())
        )
        pure
  errorCallMessage propagated `shouldBe` Just "scope failed"
  trail releases `shouldReturn` ["second", "first"]

testFacadeReverseOrderOnCancellation ∷ Expectation
testFacadeReverseOrderOnCancellation = do
  releases ← newTrail
  entered ← newEmptyMVar
  blocker ← newEmptyMVar
  outcome ← newEmptyMVar
  runner ← forkIO $ do
    captured ←
      try $
        withScoped
          ( do
              _ ← allocResource (pure ()) (\_ → record releases "first")
              _ ← allocResource (pure ()) (\_ → record releases "second")
              liftIO (putMVar entered () *> takeMVar blocker)
          )
          pure
    putMVar outcome (captured ∷ Either SomeException ())
  takeMVar entered
  killThread runner
  captured ← takeMVar outcome
  case captured of
    Right () → expectationFailure "expected the cancellation to propagate"
    Left propagated → do
      asyncException propagated `shouldBe` Just ThreadKilled
      trail releases `shouldReturn` ["second", "first"]

testFacadeEarlierFailureStopsAcquisition ∷ Expectation
testFacadeEarlierFailureStopsAcquisition = do
  steps ← newTrail
  propagated ←
    expectFailure $
      withScoped
        ( do
            _ ←
              allocResource
                (record steps "acquire first")
                (\_ → record steps "release first")
            liftIO (throwIO (ErrorCall "earlier action failed") ∷ IO ())
            _ ←
              allocResource
                (record steps "acquire second")
                (\_ → record steps "release second")
            pure ()
        )
        pure
  errorCallMessage propagated `shouldBe` Just "earlier action failed"
  -- The second acquisition is inside the failed action's continuation, so it
  -- never runs and has nothing to release.
  trail steps `shouldReturn` ["acquire first", "release first"]

testFacadeMonadIOPath ∷ Expectation
testFacadeMonadIOPath = do
  steps ← newTrail
  doubled ←
    withScoped
      ( do
          liftIO (record steps "before")
          size ← liftIO (pure (5 ∷ Int))
          value ←
            allocResource
              (record steps "acquire" *> pure size)
              (\_ → record steps "release")
          liftIO (record steps "after")
          pure (value * 2)
      )
      pure
  doubled `shouldBe` 10
  trail steps `shouldReturn` ["before", "acquire", "after", "release"]

testFacadeFunctorApplicative ∷ Expectation
testFacadeFunctorApplicative = do
  releases ← newTrail
  total ←
    withScoped
      ( (+)
          <$> fmap (* 2) (allocResource (pure (3 ∷ Int)) (\_ → record releases "first"))
          <*> allocResource (pure (4 ∷ Int)) (\_ → record releases "second")
      )
      pure
  total `shouldBe` 10
  trail releases `shouldReturn` ["second", "first"]

-- Continuation facade agreement with the direct path -------------------------

-- | The same injected outcomes through 'withResource' and through
-- 'allocResource' under 'withScoped'.
testDirectAndFacadeAgree ∷ Expectation
testDirectAndFacadeAgree = do
  directReleases ← newTrail
  facadeReleases ← newTrail
  direct ←
    expectFailure $
      withResource
        (pure ())
        (\_ → record directReleases "release" *> throwIO (userError "cleanup failed"))
        (\_ → throwIO (ErrorCall "body failed"))
  facade ←
    expectFailure $
      withScoped
        ( allocResource
            (pure ())
            (\_ → record facadeReleases "release" *> throwIO (userError "cleanup failed"))
        )
        (\_ → throwIO (ErrorCall "body failed"))
  errorCallMessage facade `shouldBe` errorCallMessage direct
  errorCallMessage facade `shouldBe` Just "body failed"
  labelsOf (cleanupFailures facade) `shouldBe` labelsOf (cleanupFailures direct)
  ioMessagesOf (cleanupFailures facade) `shouldBe` ioMessagesOf (cleanupFailures direct)
  ioMessagesOf (cleanupFailures facade) `shouldBe` [Just "cleanup failed"]
  trail facadeReleases `shouldReturn` ["release"]
  trail directReleases `shouldReturn` ["release"]

testDirectAndFacadeAgreeNested ∷ Expectation
testDirectAndFacadeAgreeNested = do
  direct ←
    expectFailure $
      withResource
        (pure ())
        (\_ → throwIO (userError "outer cleanup failed"))
        ( \_ →
            withResource
              (pure ())
              (\_ → throwIO (userError "inner cleanup failed"))
              (\_ → throwIO (ErrorCall "body failed"))
        )
  facade ←
    expectFailure $
      withScoped
        ( do
            _ ← allocResource (pure ()) (\_ → throwIO (userError "outer cleanup failed"))
            _ ← allocResource (pure ()) (\_ → throwIO (userError "inner cleanup failed"))
            liftIO (throwIO (ErrorCall "body failed") ∷ IO ())
        )
        pure
  errorCallMessage facade `shouldBe` errorCallMessage direct
  errorCallMessage facade `shouldBe` Just "body failed"
  labelsOf (cleanupFailures facade) `shouldBe` labelsOf (cleanupFailures direct)
  ioMessagesOf (cleanupFailures facade) `shouldBe` ioMessagesOf (cleanupFailures direct)
  ioMessagesOf (cleanupFailures facade)
    `shouldBe` [Just "inner cleanup failed", Just "outer cleanup failed"]

-- Continuation facade nested scopes ------------------------------------------

-- | 'locally' is a lifetime boundary: everything the inner scope allocated is
-- released before the outer scope resumes, and its ordinary result survives.
testLocallyReleasesBeforeOuterResumes ∷ Expectation
testLocallyReleasesBeforeOuterResumes = do
  steps ← newTrail
  result ←
    withScoped
      ( do
          _ ← allocResource (pure ()) (\_ → record steps "outer release")
          staged ← locally $ do
            _ ← allocResource (pure ()) (\_ → record steps "inner release")
            liftIO (record steps "inner work")
            pure (21 ∷ Int)
          liftIO (record steps "after locally")
          pure (staged * 2)
      )
      pure
  result `shouldBe` 42
  trail steps
    `shouldReturn` ["inner work", "inner release", "after locally", "outer release"]

testLocallyCleanupFailureReachesOuterScope ∷ Expectation
testLocallyCleanupFailureReachesOuterScope = do
  steps ← newTrail
  propagated ←
    expectFailure $
      withScoped
        ( do
            _ ←
              allocResource
                (pure ())
                (\_ → record steps "outer release" *> throwIO (userError "outer cleanup failed"))
            _ ← locally $ do
              _ ←
                allocResource
                  (pure ())
                  (\_ → record steps "inner release" *> throwIO (userError "inner cleanup failed"))
              pure (1 ∷ Int)
            liftIO (record steps "after locally")
        )
        pure
  -- The inner scope's body succeeded and only its release failed, so that
  -- release's exception is primary, and it reaches the outer scope, where the
  -- outer release's own failure is retained beside it.
  ioErrorMessage propagated `shouldBe` Just "inner cleanup failed"
  ioMessagesOf (cleanupFailures propagated)
    `shouldBe` [Just "inner cleanup failed", Just "outer cleanup failed"]
  trail steps `shouldReturn` ["inner release", "outer release"]

-- Continuation facade composite allocation -----------------------------------

-- | Reverse allocation order is a property of one scope's own allocations. A
-- composite allocated inside that scope keeps the order its constructor
-- declared, which for this buffer is acquisition order.
testCompositeThroughFacade ∷ Expectation
testCompositeThroughFacade = do
  device ← newDevice
  steps ← newTrail
  distinct ←
    withScoped
      ( do
          _ ← allocResource (pure ()) (\_ → record steps "surrounding release")
          first ← allocComposite (bufferAssembly device workingDevice)
          second ← allocComposite (bufferAssembly device workingDevice)
          liftIO (record steps "body")
          pure (bufferHandle first /= bufferHandle second)
      )
      pure
  distinct `shouldBe` True
  deviceTrail device
    `shouldReturn` [ "create buffer"
                   , "query requirements 1"
                   , "allocate memory 64"
                   , "bind 1 to 2"
                   , "create buffer"
                   , "query requirements 3"
                   , "allocate memory 192"
                   , "bind 3 to 4"
                   , -- The second composite is released first, because the two
                     -- allocations belong to one scope; each composite still
                     -- destroys its buffer before freeing that buffer's memory.
                     "destroy buffer 3"
                   , "free memory 4"
                   , "destroy buffer 1"
                   , "free memory 2"
                   ]
  trail steps `shouldReturn` ["body", "surrounding release"]
