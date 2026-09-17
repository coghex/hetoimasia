-- | Examples for 'Hetoimasia.Foundation.Failure'.
--
-- Every example drives the public API and inspects what a caller can see: the
-- exception that propagated, matched by its own type, and the evidence
-- 'failureEvidence' or 'failureEvidenceInContext' reads out of its context. No
-- example constructs a logger, so each one is also evidence that raising and
-- inspecting a failure need none.
--
-- Cancellation is coordinated with 'MVar's, never with a sleep.
-- 'boundedExample' only stops an example that has already hung.
module Test.Foundation.Failures.Spec (spec) where

import Control.Concurrent (forkIO, killThread)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar, tryPutMVar)
import Control.Concurrent.STM (STM, atomically, catchSTM, newTVarIO, readTVarIO, throwSTM, writeTVar)
import Control.Exception
  ( AsyncException (ThreadKilled)
  , Exception
  , ExceptionWithContext (ExceptionWithContext)
  , IOException
  , SomeException
  , annotateIO
  , catchNoPropagate
  , fromException
  , rethrowIO
  , throw
  , throwIO
  , try
  , tryWithContext
  )
import Control.Exception.Annotation (ExceptionAnnotation)
import Control.Exception.Context (displayExceptionContext, getExceptionAnnotations)
import Control.Monad (void)
import Control.Monad.IO.Class (liftIO)
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.List (isInfixOf, isPrefixOf)
import Data.Text (Text)
import qualified Data.Text as Text
import GHC.Stack (HasCallStack, callStack, getCallStack, srcLocFile, srcLocStartLine)
import Hetoimasia.Foundation.Failure
  ( FailureCause (..)
  , FailureEvidence (..)
  , FailureOrigin (..)
  , FailureSite (..)
  , Operation
  , OperationContext (..)
  , failureEvidence
  , failureEvidenceInContext
  , operation
  , throwFailure
  , throwFailureSTM
  , withOperationContext
  )
import Hetoimasia.Foundation.Log (Component, SourceLocation (..), unsafeComponent)
import Hetoimasia.Foundation.Resource
  ( acquirePart
  , allocResource
  , cleanupFailureLabel
  , cleanupFailures
  , cleanupFailuresInContext
  , releaseRank
  , withComposite
  , withResource
  , withResourceLabelled
  , withScoped
  )
import System.FilePath ((</>))
import System.IO (IOMode (ReadMode), openFile)
import System.IO.Error (ioeGetErrorString, isDoesNotExistError)
import System.IO.Temp (withSystemTempDirectory)
import System.Timeout (timeout)
import Test.Hspec
  ( Expectation
  , Spec
  , describe
  , expectationFailure
  , it
  , shouldBe
  , shouldSatisfy
  )

spec ∷ Spec
spec = describe "Failures" $ do
  describe "Failure origin" $ do
    it "keeps the original exception type and payload for a typed catch"
      testTypedCatch
    it "records the component, operation, identifiers, and call site"
      testDirectOrigin
    it "attributes a wrapper that declares HasCallStack to its own caller"
      testWrapperAttribution
    it "matches the original type through nested withResource, withComposite, and Scoped scopes"
      testTypedThroughScopes
    it "raises from inside a Scoped block through MonadIO"
      testRaisedInsideScoped

  describe "Operation context" $ do
    it "adds outer context in attachment order without replacing the origin"
      testContextOrder
    it "keeps the origin when a later handler rethrows preservingly"
      testLaterCatchSiteNeverOrigin
    it "loses the evidence through a typed try followed by a plain throwIO"
      testPlainRethrowLosesEvidence

  describe "Native causes" $ do
    it "keeps a library IOException's type and payload and records no throw site"
      testNativeLibraryCause
    it "distinguishes an engine origin from a native cause"
      testEngineAndNativeDistinguished

  describe "Resource contracts beside origin evidence" $ do
    it "retains cleanup failures beside an origin-annotated primary failure"
      testCleanupEvidenceBesideOrigin
    it "leaves a delivered cancellation unannotated with its context intact"
      (boundedExample testCancellationUnannotated)
    it "leaves an asynchronous exception raised synchronously unannotated"
      testSynchronousAsyncUnannotated
    it "records no origin for an asynchronous exception passed to throwFailure"
      testThrowFailureAsyncUnannotated

  describe "Failure inspection" $ do
    it "reads immutable evidence after its scope closed, with no logger"
      testInspectionWithoutLogger
    it "renders hostile operation and identifier text on one escaped line"
      testHostileTextRendersOneLine

  describe "Failures inside STM" $ do
    it "is caught by its own type with catchSTM and outside atomically"
      testSTMTypedCatch
    it "records the component, operation, identifiers, and call site"
      testSTMDirectOrigin
    it "attributes a wrapper that declares HasCallStack to its own caller"
      testSTMWrapperAttribution
    it "exposes evidence to a SomeException handler but not to a typed handler's value"
      testSTMEvidenceInsideCatch
    it "gains context from an enclosing withOperationContext once it escapes atomically"
      testSTMOperationContext
    it "keeps an annotation the cause already carried"
      testSTMKeepsAnnotation
    it "keeps an earlier origin and its ordered contexts"
      testSTMKeepsEarlierOrigin
    it "records no origin for an asynchronous cause and keeps its context"
      testSTMAsyncUnannotated
    it "raises a faulting identifier's own exception instead of the failure"
      testSTMFaultingIdentifier
    it "rolls back an escaping transaction and only the caught action's writes"
      testSTMRollback

-- Fixtures -------------------------------------------------------------------

-- | A component's own exception type. The foundation never imports it.
data WidgetFailure
  = WidgetMissing Text
  | WidgetBroken Int
  deriving (Eq, Show)

instance Exception WidgetFailure

-- | A caller's own annotation, used to prove existing context is kept.
newtype Marker = Marker String
  deriving (Eq, Show)

instance ExceptionAnnotation Marker

widgets ∷ Component
widgets = unsafeComponent "test.widgets"

scene ∷ Component
scene = unsafeComponent "test.scene"

loadWidget ∷ Operation
loadWidget = operation "load-widget"

renderScene ∷ Operation
renderScene = operation "render-scene"

-- | A component's wrapper over 'throwFailure'. It declares 'HasCallStack', so
-- its failures are attributed to whoever called it.
failWidget ∷ HasCallStack ⇒ WidgetFailure → IO a
failWidget = throwFailure widgets loadWidget [("widget", "w-7")]

-- | The same wrapper for a transaction.
failWidgetSTM ∷ HasCallStack ⇒ WidgetFailure → STM a
failWidgetSTM = throwFailureSTM widgets loadWidget [("widget", "w-7")]

commitScene ∷ Operation
commitScene = operation "commit-scene"

-- | Raised by an identifier that faults when it is evaluated.
data IdentifierFault = IdentifierFault
  deriving (Eq, Show)

instance Exception IdentifierFault

-- | The line this value is used on.
callLine ∷ HasCallStack ⇒ Int
callLine = case getCallStack callStack of
  (_, location) : _ → srcLocStartLine location
  [] → 0

-- | The file this value is used in.
callFile ∷ HasCallStack ⇒ Text
callFile = case getCallStack callStack of
  (_, location) : _ → Text.pack (srcLocFile location)
  [] → ""

-- | Run @action@, requiring it to fail with the given type, and return the
-- failure together with its context.
expectContext ∷ Exception e ⇒ IO a → IO (ExceptionWithContext e)
expectContext action = do
  outcome ← tryWithContext action
  case outcome of
    Left caught → pure caught
    Right _ → fail "expected the action to fail, but it returned"

originOf ∷ FailureEvidence → IO FailureOrigin
originOf evidence = case failureCause evidence of
  EngineOrigin origin → pure origin
  NativeCause → fail ("expected an engine origin, but found " <> show evidence)

-- | Run @action@, requiring it to fail, and return the failure with its
-- context, ready to pass on as a cause. A bare 'SomeException' would not do:
-- @base@ gives it a fresh context when it is thrown again.
caughtWithContext ∷ IO a → IO (ExceptionWithContext SomeException)
caughtWithContext = expectContext @SomeException

siteOf ∷ Maybe FailureSite → IO FailureSite
siteOf = maybe (fail "expected source information") pure

-- | Stop an example that has hung rather than letting the suite wait forever.
-- No example depends on this bound for its result.
boundedExample ∷ Expectation → Expectation
boundedExample action = do
  finished ← timeout (30 * 1000 * 1000) action
  case finished of
    Just () → pure ()
    Nothing → expectationFailure "the example did not finish within its bound"

-- Failure origin -------------------------------------------------------------

testTypedCatch ∷ Expectation
testTypedCatch = do
  outcome ← try (failWidget (WidgetMissing "door") ∷ IO ())
  outcome `shouldBe` Left (WidgetMissing "door")
  caught ← try (failWidget (WidgetBroken 4) ∷ IO ())
  case caught of
    Left (failure ∷ SomeException) → fromException failure `shouldBe` Just (WidgetBroken 4)
    Right () → expectationFailure "expected the failure to propagate"

testDirectOrigin ∷ Expectation
testDirectOrigin = do
  (line, ExceptionWithContext context failure) ← (callLine,) <$> expectContext (throwFailure widgets loadWidget [("widget", "w-1"), ("attempt", "2")] (WidgetBroken 1) ∷ IO ())
  failure `shouldBe` WidgetBroken 1
  origin ← originOf (failureEvidenceInContext context)
  originComponent origin `shouldBe` widgets
  originOperation origin `shouldBe` loadWidget
  originIdentifiers origin `shouldBe` [("widget", "w-1"), ("attempt", "2")]
  site ← siteOf (originSite origin)
  siteLocation site `shouldBe` SourceLocation callFile line "throwFailure"
  siteCallStack site `shouldBe` [SourceLocation callFile line "throwFailure"]

testWrapperAttribution ∷ Expectation
testWrapperAttribution = do
  (line, ExceptionWithContext context failure) ← (callLine,) <$> expectContext (failWidget (WidgetMissing "lid") ∷ IO ())
  failure `shouldBe` WidgetMissing "lid"
  origin ← originOf (failureEvidenceInContext context)
  site ← siteOf (originSite origin)
  -- The outermost frame is this example's call to the wrapper, not the line
  -- inside the wrapper, and no list of helper names was consulted to find it.
  siteLocation site `shouldBe` SourceLocation callFile line "failWidget"
  map sourceFunction (siteCallStack site) `shouldBe` ["throwFailure", "failWidget"]
  case map sourceLine (siteCallStack site) of
    [inner, outer] → do
      outer `shouldBe` line
      inner `shouldSatisfy` (/= line)
    other → expectationFailure ("expected two frames, found " <> show other)

testTypedThroughScopes ∷ Expectation
testTypedThroughScopes = do
  let nested ∷ IO ()
      nested =
        withResource (pure ()) (\_ → pure ()) $ \_ →
          withComposite (acquirePart "part" (releaseRank 0) (pure ()) (\_ → pure ())) $ \_ →
            withScoped (allocResource (pure ()) (\_ → pure ())) $ \_ →
              withOperationContext scene renderScene [] $
                failWidget (WidgetMissing "deep")
  plain ← try nested
  plain `shouldBe` Left (WidgetMissing "deep")
  ExceptionWithContext context failure ← expectContext @WidgetFailure nested
  failure `shouldBe` WidgetMissing "deep"
  evidence ← pure (failureEvidenceInContext context)
  origin ← originOf evidence
  originOperation origin `shouldBe` loadWidget
  map contextOperation (failureContexts evidence) `shouldBe` [renderScene]

testRaisedInsideScoped ∷ Expectation
testRaisedInsideScoped = do
  released ← newIORef False
  outcome ← try $
    withScoped
      ( do
          _ ← allocResource (pure ()) (\_ → writeIORef released True)
          liftIO (pure ())
          throwFailure widgets loadWidget [] (WidgetBroken 9)
      )
      (\() → pure ())
  case outcome of
    Left (failure ∷ SomeException) → do
      fromException failure `shouldBe` Just (WidgetBroken 9)
      origin ← originOf (failureEvidence failure)
      originComponent origin `shouldBe` widgets
    Right () → expectationFailure "expected the failure to propagate"
  readIORef released `shouldReturnValue` True

-- Operation context ----------------------------------------------------------

testContextOrder ∷ Expectation
testContextOrder = do
  (line, ExceptionWithContext context failure) ←
    (callLine,) <$> expectContext (withOperationContext scene renderScene [("frame", "12")] (withOperationContext widgets loadWidget [] (failWidget (WidgetBroken 2))) ∷ IO ())
  failure `shouldBe` WidgetBroken 2
  let evidence = failureEvidenceInContext context
  origin ← originOf evidence
  site ← siteOf (originSite origin)
  siteLocation site `shouldBe` SourceLocation callFile line "failWidget"
  map contextOperation (failureContexts evidence) `shouldBe` [loadWidget, renderScene]
  map contextComponent (failureContexts evidence) `shouldBe` [widgets, scene]
  map contextIdentifiers (failureContexts evidence) `shouldBe` [[], [("frame", "12")]]
  boundaries ← traverse (siteOf . contextBoundary) (failureContexts evidence)
  map siteLocation boundaries
    `shouldBe` [ SourceLocation callFile line "withOperationContext"
               , SourceLocation callFile line "withOperationContext"
               ]

testLaterCatchSiteNeverOrigin ∷ Expectation
testLaterCatchSiteNeverOrigin = do
  (line, raised) ← (callLine,) <$> pure (failWidget (WidgetMissing "hinge") ∷ IO ())
  ExceptionWithContext context failure ←
    expectContext @SomeException $
      withOperationContext scene renderScene [] $
        -- A handler that inspects and rethrows preservingly, and then a second
        -- one through try, both far from the throw site.
        ( do
            outcome ← tryWithContext @SomeException (raised `catchNoPropagate` \caught → rethrowIO (caught ∷ ExceptionWithContext SomeException))
            either rethrowIO pure outcome
        )
  fromException failure `shouldBe` Just (WidgetMissing "hinge")
  let evidence = failureEvidenceInContext context
  origin ← originOf evidence
  site ← siteOf (originSite origin)
  siteLocation site `shouldBe` SourceLocation callFile line "failWidget"
  map contextOperation (failureContexts evidence) `shouldBe` [renderScene]

testPlainRethrowLosesEvidence ∷ Expectation
testPlainRethrowLosesEvidence = do
  ExceptionWithContext context failure ←
    expectContext @WidgetFailure $ do
      outcome ← try (failWidget (WidgetBroken 5) ∷ IO ())
      either throwIO pure (outcome ∷ Either WidgetFailure ())
  -- The type and value survive; the evidence does not.
  failure `shouldBe` WidgetBroken 5
  failureEvidenceInContext context `shouldBe` FailureEvidence NativeCause []

-- Native causes --------------------------------------------------------------

testNativeLibraryCause ∷ Expectation
testNativeLibraryCause =
  withSystemTempDirectory "hetoimasia-failure" $ \directory → do
    let absent = directory </> "absent-widget"
    ExceptionWithContext context failure ←
      expectContext @IOException $
        withOperationContext widgets loadWidget [("path", Text.pack absent)] $
          void (openFile absent ReadMode)
    failure `shouldSatisfy` isDoesNotExistError
    let evidence = failureEvidenceInContext context
    failureCause evidence `shouldBe` NativeCause
    case failureContexts evidence of
      [boundary] → do
        contextComponent boundary `shouldBe` widgets
        contextOperation boundary `shouldBe` loadWidget
        contextIdentifiers boundary `shouldBe` [("path", Text.pack absent)]
        site ← siteOf (contextBoundary boundary)
        sourceFunction (siteLocation site) `shouldBe` "withOperationContext"
      other → expectationFailure ("expected one operation context, found " <> show other)

testEngineAndNativeDistinguished ∷ Expectation
testEngineAndNativeDistinguished = do
  let boundary = withOperationContext widgets loadWidget []
  engine ← try (boundary (failWidget (WidgetMissing "knob")) ∷ IO ())
  native ← try (boundary (ioError (userError "native widget failure")) ∷ IO ())
  case (engine, native) of
    (Left (engineFailure ∷ SomeException), Left (nativeFailure ∷ SomeException)) → do
      failureCause (failureEvidence engineFailure) `shouldSatisfy` isEngineOrigin
      failureCause (failureEvidence nativeFailure) `shouldBe` NativeCause
      -- The native exception is still an IOException with its own message,
      -- not an engine exception carrying its text.
      fmap ioeGetErrorString (fromException nativeFailure) `shouldBe` Just "native widget failure"
      (fromException nativeFailure ∷ Maybe WidgetFailure) `shouldBe` Nothing
    _ → expectationFailure "expected both operations to fail"
  where
    isEngineOrigin (EngineOrigin _) = True
    isEngineOrigin NativeCause = False

-- Resource contracts ---------------------------------------------------------

testCleanupEvidenceBesideOrigin ∷ Expectation
testCleanupEvidenceBesideOrigin = do
  ExceptionWithContext context failure ←
    expectContext @SomeException $
      withOperationContext scene renderScene [] $
        withResourceLabelled "widget cache" (pure ()) (\_ → ioError (userError "cache release failed")) $ \_ →
          failWidget (WidgetMissing "cache") ∷ IO ()
  fromException failure `shouldBe` Just (WidgetMissing "cache")
  map cleanupFailureLabel (cleanupFailuresInContext context) `shouldBe` ["widget cache"]
  map cleanupFailureLabel (cleanupFailures failure) `shouldBe` ["widget cache"]
  let evidence = failureEvidenceInContext context
  origin ← originOf evidence
  originOperation origin `shouldBe` loadWidget
  map contextOperation (failureContexts evidence) `shouldBe` [renderScene]

testCancellationUnannotated ∷ Expectation
testCancellationUnannotated = do
  entered ← newEmptyMVar
  never ← newEmptyMVar
  result ← newEmptyMVar
  worker ← forkIO $ do
    outcome ←
      tryWithContext @SomeException $
        withOperationContext widgets loadWidget [] $
          annotateIO (Marker "inside the operation") $ do
            putMVar entered ()
            takeMVar never
    putMVar result outcome
  takeMVar entered
  killThread worker
  outcome ← takeMVar result
  -- Keeps the blocking slot reachable until the cancellation was observed.
  void (tryPutMVar never ())
  case outcome of
    Left (ExceptionWithContext context cancellation) → do
      fromException cancellation `shouldBe` Just ThreadKilled
      failureEvidenceInContext context `shouldBe` FailureEvidence NativeCause []
      (getExceptionAnnotations context ∷ [Marker]) `shouldBe` [Marker "inside the operation"]
    Right () → expectationFailure "expected the operation to be cancelled"

testSynchronousAsyncUnannotated ∷ Expectation
testSynchronousAsyncUnannotated = do
  ExceptionWithContext context cancellation ←
    expectContext @SomeException $
      withOperationContext widgets loadWidget [] $
        annotateIO (Marker "kept") (throwIO ThreadKilled ∷ IO ())
  fromException cancellation `shouldBe` Just ThreadKilled
  failureEvidenceInContext context `shouldBe` FailureEvidence NativeCause []
  (getExceptionAnnotations context ∷ [Marker]) `shouldBe` [Marker "kept"]

testThrowFailureAsyncUnannotated ∷ Expectation
testThrowFailureAsyncUnannotated = do
  ExceptionWithContext context cancellation ←
    expectContext @SomeException $
      withOperationContext scene renderScene [] $
        (throwFailure widgets loadWidget [] ThreadKilled ∷ IO ())
  fromException cancellation `shouldBe` Just ThreadKilled
  failureEvidenceInContext context `shouldBe` FailureEvidence NativeCause []

-- Inspection -----------------------------------------------------------------

testInspectionWithoutLogger ∷ Expectation
testInspectionWithoutLogger = do
  -- The identifier is copied out of a handle the scope owns; the evidence is
  -- read after that handle has been released.
  handle ← newIORef ("buffer-3" ∷ Text)
  ExceptionWithContext context _ ←
    expectContext @WidgetFailure $
      withResource (pure handle) (\owned → writeIORef owned "released") $ \owned → do
        name ← readIORef owned
        failWidget (WidgetMissing name) ∷ IO ()
  readIORef handle `shouldReturnValue` "released"
  let evidence = failureEvidenceInContext context
  evidence `shouldBe` failureEvidenceInContext context
  origin ← originOf evidence
  originIdentifiers origin `shouldBe` [("widget", "w-7")]
  let rendered = displayExceptionContext context
  rendered `shouldSatisfy` isInfixOf "failure origin: test.widgets \"load-widget\" (\"widget\"=\"w-7\")"

shouldReturnValue ∷ (Eq a, Show a) ⇒ IO a → a → Expectation
shouldReturnValue action expected = action >>= (`shouldBe` expected)

testHostileTextRendersOneLine ∷ Expectation
testHostileTextRendersOneLine = do
  let forged = "a.png\nduring operation: test.scene forged"
  ExceptionWithContext context _ ←
    expectContext @WidgetFailure $
      withOperationContext scene (operation "render\r\"scene\"") [("frame\n", "1")] $
        (throwFailure widgets loadWidget [("path", forged)] (WidgetMissing "hostile") ∷ IO ())
  let rendered = lines (displayExceptionContext context)
  -- Exactly one line per piece of evidence, and the hostile text escaped
  -- inside quotes rather than starting a line of its own.
  let starting label = filter (isPrefixOf label . dropWhile (== ' ')) rendered
  length (starting "failure origin:") `shouldBe` 1
  length (starting "during operation:") `shouldBe` 1
  filter (isInfixOf "forged") rendered `shouldBe` starting "failure origin:"
  rendered `shouldSatisfy` any (isInfixOf "(\"path\"=\"a.png\\nduring operation: test.scene forged\")")
  rendered `shouldSatisfy` any (isInfixOf "test.scene \"render\\r\\\"scene\\\"\" (\"frame\\n\"=\"1\")")

-- Failures inside STM --------------------------------------------------------

testSTMTypedCatch ∷ Expectation
testSTMTypedCatch = do
  engine ← try (atomically (failWidgetSTM (WidgetMissing "valve")) ∷ IO ())
  engine `shouldBe` Left (WidgetMissing "valve")
  native ← try @IOException (atomically (throwFailureSTM widgets loadWidget [] (userError "native stm failure")) ∷ IO ())
  either (Just . ioeGetErrorString) (const Nothing) native `shouldBe` Just "native stm failure"
  caughtEngine ←
    atomically $
      (failWidgetSTM (WidgetBroken 3) >> pure Nothing) `catchSTM` \(failure ∷ WidgetFailure) → pure (Just failure)
  caughtEngine `shouldBe` Just (WidgetBroken 3)
  caughtNative ←
    atomically $
      (throwFailureSTM widgets loadWidget [] (userError "caught stm failure") >> pure Nothing)
        `catchSTM` \(failure ∷ IOException) → pure (Just (ioeGetErrorString failure))
  caughtNative `shouldBe` Just "caught stm failure"

testSTMDirectOrigin ∷ Expectation
testSTMDirectOrigin = do
  (line, ExceptionWithContext context failure) ← (callLine,) <$> expectContext (atomically (throwFailureSTM widgets loadWidget [("widget", "w-1"), ("attempt", "2")] (WidgetBroken 1)) ∷ IO ())
  failure `shouldBe` WidgetBroken 1
  let evidence = failureEvidenceInContext context
  failureContexts evidence `shouldBe` []
  origin ← originOf evidence
  originComponent origin `shouldBe` widgets
  originOperation origin `shouldBe` loadWidget
  originIdentifiers origin `shouldBe` [("widget", "w-1"), ("attempt", "2")]
  site ← siteOf (originSite origin)
  siteLocation site `shouldBe` SourceLocation callFile line "throwFailureSTM"
  siteCallStack site `shouldBe` [SourceLocation callFile line "throwFailureSTM"]

testSTMWrapperAttribution ∷ Expectation
testSTMWrapperAttribution = do
  (line, ExceptionWithContext context failure) ← (callLine,) <$> expectContext (atomically (failWidgetSTM (WidgetMissing "lid")) ∷ IO ())
  failure `shouldBe` WidgetMissing "lid"
  origin ← originOf (failureEvidenceInContext context)
  site ← siteOf (originSite origin)
  siteLocation site `shouldBe` SourceLocation callFile line "failWidgetSTM"
  map sourceFunction (siteCallStack site) `shouldBe` ["throwFailureSTM", "failWidgetSTM"]
  case map sourceLine (siteCallStack site) of
    [inner, outer] → do
      outer `shouldBe` line
      inner `shouldSatisfy` (/= line)
    other → expectationFailure ("expected two frames, found " <> show other)

testSTMEvidenceInsideCatch ∷ Expectation
testSTMEvidenceInsideCatch = do
  -- A SomeException handler reads the evidence without leaving the transaction.
  (line, inspected) ←
    (callLine,) <$> atomically ((failWidgetSTM (WidgetBroken 3) >> pure Nothing) `catchSTM` \(caught ∷ SomeException) → pure (Just (fromException caught, failureEvidence caught)))
  case inspected of
    Just (failure, evidence) → do
      failure `shouldBe` Just (WidgetBroken 3)
      origin ← originOf evidence
      site ← siteOf (originSite origin)
      siteLocation site `shouldBe` SourceLocation callFile line "failWidgetSTM"
    Nothing → expectationFailure "expected the handler to run"
  -- A typed handler matches, but holds only the value: rethrowing it raises
  -- the same type and value with no evidence.
  ExceptionWithContext context failure ←
    expectContext @WidgetFailure $
      atomically (failWidgetSTM (WidgetBroken 5) `catchSTM` \(caught ∷ WidgetFailure) → throwSTM caught ∷ STM ())
  failure `shouldBe` WidgetBroken 5
  failureEvidenceInContext context `shouldBe` FailureEvidence NativeCause []

testSTMOperationContext ∷ Expectation
testSTMOperationContext = do
  (line, ExceptionWithContext context failure) ←
    (callLine,) <$> expectContext (withOperationContext scene renderScene [("frame", "12")] (atomically (failWidgetSTM (WidgetBroken 2))) ∷ IO ())
  failure `shouldBe` WidgetBroken 2
  let evidence = failureEvidenceInContext context
  origin ← originOf evidence
  site ← siteOf (originSite origin)
  siteLocation site `shouldBe` SourceLocation callFile line "failWidgetSTM"
  map contextOperation (failureContexts evidence) `shouldBe` [renderScene]
  map contextIdentifiers (failureContexts evidence) `shouldBe` [[("frame", "12")]]

testSTMKeepsAnnotation ∷ Expectation
testSTMKeepsAnnotation = do
  cause ← caughtWithContext (annotateIO (Marker "carried") (throwIO (WidgetBroken 4)) ∷ IO ())
  ExceptionWithContext context failure ←
    expectContext @WidgetFailure (atomically (throwFailureSTM scene commitScene [("scene", "s-2")] cause) ∷ IO ())
  failure `shouldBe` WidgetBroken 4
  (getExceptionAnnotations context ∷ [Marker]) `shouldBe` [Marker "carried"]
  origin ← originOf (failureEvidenceInContext context)
  originComponent origin `shouldBe` scene
  originOperation origin `shouldBe` commitScene
  originIdentifiers origin `shouldBe` [("scene", "s-2")]

testSTMKeepsEarlierOrigin ∷ Expectation
testSTMKeepsEarlierOrigin = do
  (line, cause) ← (callLine,) <$> caughtWithContext (withOperationContext widgets loadWidget [] (failWidget (WidgetMissing "seal")) ∷ IO ())
  ExceptionWithContext context failure ←
    expectContext @WidgetFailure $
      withOperationContext scene renderScene [] (atomically (throwFailureSTM scene commitScene [] cause) ∷ IO ())
  failure `shouldBe` WidgetMissing "seal"
  let evidence = failureEvidenceInContext context
  origin ← originOf evidence
  originOperation origin `shouldBe` loadWidget
  site ← siteOf (originSite origin)
  siteLocation site `shouldBe` SourceLocation callFile line "failWidget"
  map contextOperation (failureContexts evidence) `shouldBe` [loadWidget, renderScene]

testSTMAsyncUnannotated ∷ Expectation
testSTMAsyncUnannotated = do
  cause ← caughtWithContext (annotateIO (Marker "kept") (throwIO ThreadKilled) ∷ IO ())
  ExceptionWithContext context cancellation ←
    expectContext @SomeException (atomically (throwFailureSTM widgets loadWidget [] cause) ∷ IO ())
  fromException cancellation `shouldBe` Just ThreadKilled
  failureEvidenceInContext context `shouldBe` FailureEvidence NativeCause []
  (getExceptionAnnotations context ∷ [Marker]) `shouldBe` [Marker "kept"]
  ExceptionWithContext bareContext bare ←
    expectContext @SomeException (atomically (throwFailureSTM widgets loadWidget [] ThreadKilled) ∷ IO ())
  fromException bare `shouldBe` Just ThreadKilled
  failureEvidenceInContext bareContext `shouldBe` FailureEvidence NativeCause []

testSTMFaultingIdentifier ∷ Expectation
testSTMFaultingIdentifier = do
  ExceptionWithContext context failure ←
    expectContext @SomeException (atomically (throwFailureSTM widgets loadWidget [("widget", throw IdentifierFault)] (WidgetBroken 8)) ∷ IO ())
  fromException failure `shouldBe` Just IdentifierFault
  (fromException failure ∷ Maybe WidgetFailure) `shouldBe` Nothing
  failureCause (failureEvidenceInContext context) `shouldBe` NativeCause

testSTMRollback ∷ Expectation
testSTMRollback = do
  escaped ← newTVarIO (0 ∷ Int)
  outcome ← try (atomically (writeTVar escaped 1 >> failWidgetSTM (WidgetBroken 6)) ∷ IO ())
  outcome `shouldBe` Left (WidgetBroken 6)
  readTVarIO escaped `shouldReturnValue` 0
  before ← newTVarIO (0 ∷ Int)
  guarded ← newTVarIO (0 ∷ Int)
  caught ← atomically $ do
    writeTVar before 1
    (writeTVar guarded 1 >> failWidgetSTM (WidgetBroken 7) >> pure Nothing)
      `catchSTM` \(failure ∷ WidgetFailure) → pure (Just failure)
  caught `shouldBe` Just (WidgetBroken 7)
  readTVarIO before `shouldReturnValue` 1
  readTVarIO guarded `shouldReturnValue` 0
