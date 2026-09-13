-- | Examples for 'Hetoimasia.Foundation.Recovery'.
--
-- Every example drives 'recover' with injected typed failures inside real CPU
-- scopes and observes what a caller can see: the returned 'Outcome', or the
-- failure that propagated together with its origin, cleanup, and recovery
-- evidence. Ordering is observed through an append-only trace. No example
-- constructs a logger.
--
-- Cancellation is coordinated with 'MVar's, never with a sleep.
-- 'boundedExample' only stops an example that has already hung.
module Test.Engine.Recovery.Spec (spec) where

import Control.Concurrent (forkIO, killThread)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar, tryPutMVar)
import Control.Exception
  ( AsyncException (ThreadKilled)
  , Exception
  , ExceptionWithContext (ExceptionWithContext)
  , IOException
  , SomeException
  , WhileHandling (WhileHandling)
  , annotateIO
  , fromException
  , someExceptionContext
  , throw
  , throwIO
  , try
  , tryWithContext
  )
import Control.Exception.Annotation (ExceptionAnnotation)
import Control.Exception.Context (ExceptionContext, getExceptionAnnotations)
import Control.Monad (void)
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef, writeIORef)
import Data.Text (Text)
import qualified Data.Text as Text
import Hetoimasia.Foundation.Failure
  ( FailureCause (..)
  , FailureEvidence (failureCause)
  , FailureOrigin (..)
  , Operation
  , failureEvidenceInContext
  , operation
  , throwFailure
  )
import Hetoimasia.Foundation.Log (Component, unsafeComponent)
import Hetoimasia.Foundation.Recovery
  ( AttemptFailure (..)
  , AttemptKind (..)
  , Disposition (..)
  , InvalidRecoveryPolicy (..)
  , Outcome (..)
  , Recovered (..)
  , RecoveryHistory (..)
  , RecoveryPolicy (..)
  , Strategy (..)
  , Unavailability (..)
  , recover
  , recoveryHistory
  , recoveryHistoryInContext
  )
import Hetoimasia.Foundation.Resource
  ( allocResource
  , cleanupFailureLabel
  , cleanupFailuresInContext
  , withResourceLabelled
  , withScoped
  )
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
spec = describe "Recovery" $ do
  describe "Complete owned operations" $ do
    it "finishes a failed attempt's release before the wait and the fallback start"
      testReleaseBeforeFallback
    it "leaves an enclosing scope's resource valid after recovery"
      testEnclosingScopeUsable
    it "returns a first-attempt success without consulting the classifier"
      testFirstAttemptSuccess
    it "evaluates the result inside the attempt"
      testResultEvaluatedInsideAttempt
    it "neither catches nor retries a caller failure after the boundary, and runs it once"
      testCallerFailureOutsideBoundary

  describe "Policy and budget" $ do
    it "rejects a non-positive budget before any effect"
      testInvalidBudget
    it "exhausts one budget across a retry-then-fallback strategy change"
      testBudgetAcrossStrategies

  describe "Outcomes" $ do
    it "recovers by retry with its status and history"
      testRecoveredByRetry
    it "propagates required exhaustion with earlier attempts, origins, and cleanup evidence in order"
      testRequiredExhaustion
    it "returns an explicit unavailable outcome for exhausted optional work"
      testOptionalExhaustion

  describe "Failures that stop recovery" $ do
    it "propagates an unrecognized first failure unchanged"
      testUnrecognizedUnchanged
    it "propagates an attempt with cleanup evidence without classifying it"
      testCleanupEvidenceStops
    it "stops on a classifier failure, keeping the handled failure as context"
      testClassifierFailure
    it "stops on a wait failure, keeping the handled failure as context"
      testWaitFailure
    it "keeps earlier history when a later failure is unrecognized"
      testEarlyStopUnrecognizedHistory
    it "keeps earlier history when the terminal attempt's cleanup fails"
      testEarlyStopCleanupHistory

  describe "Optional work with a budget of one" $ do
    it "does not downgrade an unrecognized failure"
      testBudgetOneUnrecognized
    it "does not downgrade a cleanup failure or classify it"
      testBudgetOneCleanup
    it "does not downgrade a cancellation or classify it"
      testBudgetOneCancellation

  describe "Cancellation" $ do
    it "escapes cancellation during work with its own context and cleanup evidence"
      (boundedExample testCancelDuringWork)
    it "escapes cancellation during classification"
      (boundedExample testCancelDuringClassification)
    it "escapes cancellation during the wait"
      (boundedExample testCancelDuringWait)
    it "escapes cancellation during a fallback"
      (boundedExample testCancelDuringFallback)

-- Fixtures -------------------------------------------------------------------

-- | A component's own exception type. The foundation never imports it.
data WidgetFailure
  = WidgetBroken Int
  | WidgetUnknown
  deriving (Eq, Show)

instance Exception WidgetFailure

-- | A caller's own annotation, used to prove existing context is kept.
newtype Marker = Marker String
  deriving (Eq, Show)

instance ExceptionAnnotation Marker

widgets ∷ Component
widgets = unsafeComponent "test.widgets"

loadWidget ∷ Operation
loadWidget = operation "load-widget"

cachedWidget ∷ Operation
cachedWidget = operation "cached-widget"

-- | Fail one attempt with an engine origin naming it.
failAttempt ∷ Int → IO a
failAttempt number =
  throwFailure widgets loadWidget [("attempt", Text.pack (show number))] (WidgetBroken number)

policy ∷ Disposition → Int → (AttemptFailure → IO (Maybe (Strategy a))) → RecoveryPolicy a
policy disposition budget classifier =
  RecoveryPolicy
    { policyDisposition = disposition
    , policyBudget = budget
    , policyClassifier = classifier
    , policyWait = \_ → pure ()
    }

-- | Recognize 'WidgetBroken' with one strategy and nothing else.
recognizeBroken ∷ Strategy a → AttemptFailure → IO (Maybe (Strategy a))
recognizeBroken strategy failure = pure $ case failureOf failure of
  Just (WidgetBroken _) → Just strategy
  _ → Nothing

failureOf ∷ Exception e ⇒ AttemptFailure → Maybe e
failureOf failure = case attemptException failure of
  ExceptionWithContext _ exception → fromException exception

contextOf ∷ AttemptFailure → ExceptionContext
contextOf failure = case attemptException failure of
  ExceptionWithContext context _ → context

newTrace ∷ IO (IORef [Text])
newTrace = newIORef []

record ∷ IORef [Text] → Text → IO ()
record trace entry = atomicModifyIORef' trace (\entries → (entries <> [entry], ()))

newCounter ∷ IO (IORef Int)
newCounter = newIORef 0

bump ∷ IORef Int → IO Int
bump counter = atomicModifyIORef' counter (\n → (n + 1, n + 1))

-- | Wrap a classifier so its invocations are counted.
counted ∷ IORef Int → (AttemptFailure → IO b) → AttemptFailure → IO b
counted counter classifier failure = bump counter >> classifier failure

expectAvailable ∷ Outcome a → IO (Recovered a)
expectAvailable (Available recovered) = pure recovered
expectAvailable (Unavailable reason) = fail ("expected an available result, found " <> show reason)

-- | Run @action@, requiring it to fail with the given type.
expectContext ∷ Exception e ⇒ IO a → IO (ExceptionWithContext e)
expectContext action = do
  outcome ← tryWithContext action
  case outcome of
    Left caught → pure caught
    Right _ → fail "expected the boundary to propagate a failure, but it returned"

attemptOrigin ∷ ExceptionContext → Maybe [(Text, Text)]
attemptOrigin context = case failureCause (failureEvidenceInContext context) of
  EngineOrigin origin → Just (originIdentifiers origin)
  NativeCause → Nothing

attemptLabel ∷ Int → Maybe [(Text, Text)]
attemptLabel number = Just [("attempt", Text.pack (show number))]

handledFailures ∷ ExceptionContext → [SomeException]
handledFailures context = [handled | WhileHandling handled ← getExceptionAnnotations context]

-- | Stop an example that has hung rather than letting the suite wait forever.
-- No example depends on this bound for its result.
boundedExample ∷ Expectation → Expectation
boundedExample action = do
  finished ← timeout (30 * 1000 * 1000) action
  case finished of
    Just () → pure ()
    Nothing → expectationFailure "the example did not finish within its bound"

-- | Run a scenario on its own thread, cancel it once it reports that it is
-- blocked, and return what escaped the boundary.
--
-- The scenario receives the blocking step to place where the cancellation must
-- arrive. That step annotates itself with a 'Marker', so an example can check
-- that the cancellation kept the context it was delivered with.
cancelledScenario ∷ (IO () → IO (Outcome ())) → IO (ExceptionWithContext SomeException)
cancelledScenario scenario = do
  entered ← newEmptyMVar
  never ← newEmptyMVar
  result ← newEmptyMVar
  let blocked = annotateIO (Marker "blocked") (putMVar entered () >> takeMVar never)
  worker ← forkIO (tryWithContext (scenario blocked) >>= putMVar result)
  takeMVar entered
  killThread worker
  outcome ← takeMVar result
  -- Keeps the blocking slot reachable until the cancellation was observed.
  void (tryPutMVar never ())
  case outcome of
    Left caught → pure caught
    Right _ → fail "expected the scenario to be cancelled, but it returned"

-- | What every escaped cancellation must look like: itself, with its delivery
-- context, and with nothing recovery-related added.
expectPlainCancellation ∷ ExceptionWithContext SomeException → Expectation
expectPlainCancellation (ExceptionWithContext context cancellation) = do
  fromException cancellation `shouldBe` Just ThreadKilled
  (getExceptionAnnotations context ∷ [Marker]) `shouldBe` [Marker "blocked"]
  length (recoveryHistoryInContext context) `shouldBe` 0
  length (handledFailures context) `shouldBe` 0

-- Complete owned operations --------------------------------------------------

testReleaseBeforeFallback ∷ Expectation
testReleaseBeforeFallback = do
  trace ← newTrace
  let classifier failure = do
        record trace "classify"
        recognizeBroken (Fallback cachedWidget (record trace "fallback" >> pure "cached")) failure
      waiting number = record trace ("wait " <> Text.pack (show number))
  outcome ←
    recover loadWidget ((policy Required 2 classifier) {policyWait = waiting}) $
      withScoped (allocResource (record trace "acquire") (\() → record trace "release")) $ \() → do
        record trace "work"
        failAttempt 1
  readIORef trace `shouldReturn` ["acquire", "work", "release", "classify", "wait 2", "fallback"]
  recovered ← expectAvailable outcome
  recoveredValue recovered `shouldBe` ("cached" ∷ Text)
  recoveredBy recovered `shouldBe` FallbackAttempt cachedWidget
  map attemptNumber (recoveredFailures recovered) `shouldBe` [1]
  map attemptKind (recoveredFailures recovered) `shouldBe` [InitialAttempt]
  map (attemptOrigin . contextOf) (recoveredFailures recovered) `shouldBe` [attemptLabel 1]

testEnclosingScopeUsable ∷ Expectation
testEnclosingScopeUsable = do
  innerReleases ← newCounter
  outerState ← newIORef ("unacquired" ∷ Text)
  attempts ← newCounter
  observed ←
    withScoped (allocResource (writeIORef outerState "live" >> pure outerState) (`writeIORef` "released")) $ \outer → do
      outcome ←
        recover loadWidget (policy Required 2 (recognizeBroken Retry)) $
          withScoped (allocResource (pure ()) (\() → void (bump innerReleases))) $ \() → do
            number ← bump attempts
            if number == 1 then failAttempt 1 else readIORef outer
      recovered ← expectAvailable outcome
      -- The enclosing resource is still live after recovery finished.
      afterwards ← readIORef outer
      pure (recoveredValue recovered, recoveredBy recovered, afterwards)
  observed `shouldBe` ("live", RetryAttempt, "live")
  readIORef innerReleases `shouldReturn` 2
  readIORef outerState `shouldReturn` "released"

testFirstAttemptSuccess ∷ Expectation
testFirstAttemptSuccess = do
  classified ← newCounter
  outcome ← recover loadWidget (policy Optional 3 (counted classified (recognizeBroken Retry))) (pure (7 ∷ Int))
  recovered ← expectAvailable outcome
  recoveredValue recovered `shouldBe` 7
  recoveredBy recovered `shouldBe` InitialAttempt
  length (recoveredFailures recovered) `shouldBe` 0
  readIORef classified `shouldReturn` 0

testResultEvaluatedInsideAttempt ∷ Expectation
testResultEvaluatedInsideAttempt = do
  attempts ← newCounter
  outcome ←
    recover loadWidget (policy Required 2 (recognizeBroken Retry)) $ do
      number ← bump attempts
      pure (if number == 1 then throw (WidgetBroken 1) else number)
  recovered ← expectAvailable outcome
  recoveredValue recovered `shouldBe` 2
  map failureOf (recoveredFailures recovered) `shouldBe` [Just (WidgetBroken 1)]

testCallerFailureOutsideBoundary ∷ Expectation
testCallerFailureOutsideBoundary = do
  attempts ← newCounter
  continuation ← newCounter
  outcome ←
    try $
      withScoped (allocResource (pure ()) (\() → pure ())) $ \() → do
        recovered ←
          recover loadWidget (policy Required 3 (recognizeBroken Retry)) $ do
            number ← bump attempts
            if number == 1 then failAttempt 1 else pure ()
        _ ← expectAvailable recovered
        _ ← bump continuation
        throwIO (WidgetBroken 99) ∷ IO ()
  outcome `shouldBe` Left (WidgetBroken 99)
  readIORef attempts `shouldReturn` 2
  readIORef continuation `shouldReturn` 1

-- Policy and budget ----------------------------------------------------------

testInvalidBudget ∷ Expectation
testInvalidBudget = do
  effects ← newCounter
  let invalid budget =
        RecoveryPolicy
          { policyDisposition = Optional
          , policyBudget = budget
          , policyClassifier = \_ → bump effects >> pure (Just Retry)
          , policyWait = \_ → void (bump effects)
          }
  zero ← try (recover loadWidget (invalid 0) (bump effects))
  negative ← try (recover loadWidget (invalid (-2)) (bump effects))
  either Just (const Nothing) zero `shouldBe` Just (NonPositiveBudget 0)
  either Just (const Nothing) negative `shouldBe` Just (NonPositiveBudget (-2))
  readIORef effects `shouldReturn` 0

testBudgetAcrossStrategies ∷ Expectation
testBudgetAcrossStrategies = do
  originals ← newCounter
  fallbacks ← newCounter
  classified ← newCounter
  let fallback = bump fallbacks >> failAttempt 3
      classifier failure = do
        _ ← bump classified
        pure . Just $ case attemptKind failure of
          InitialAttempt → Retry
          RetryAttempt → Fallback cachedWidget fallback
          -- The strategy changes back; the budget must not reset.
          FallbackAttempt _ → Retry
  ExceptionWithContext context failure ←
    expectContext @WidgetFailure $
      recover loadWidget (policy Required 3 classifier) (bump originals >>= failAttempt)
  failure `shouldBe` WidgetBroken 3
  readIORef originals `shouldReturn` 2
  readIORef fallbacks `shouldReturn` 1
  readIORef classified `shouldReturn` 3
  map (map attemptKind . historyAttempts) (recoveryHistoryInContext context)
    `shouldBe` [[InitialAttempt, RetryAttempt]]

-- Outcomes -------------------------------------------------------------------

testRecoveredByRetry ∷ Expectation
testRecoveredByRetry = do
  attempts ← newCounter
  outcome ←
    recover loadWidget (policy Required 3 (recognizeBroken Retry)) $ do
      number ← bump attempts
      if number < 3 then failAttempt number else pure ("fresh" ∷ Text)
  recovered ← expectAvailable outcome
  recoveredValue recovered `shouldBe` "fresh"
  recoveredBy recovered `shouldBe` RetryAttempt
  map attemptNumber (recoveredFailures recovered) `shouldBe` [1, 2]
  map attemptKind (recoveredFailures recovered) `shouldBe` [InitialAttempt, RetryAttempt]
  map failureOf (recoveredFailures recovered) `shouldBe` [Just (WidgetBroken 1), Just (WidgetBroken 2)]

testRequiredExhaustion ∷ Expectation
testRequiredExhaustion = do
  attempts ← newCounter
  released ← newCounter
  ExceptionWithContext context failure ←
    expectContext @WidgetFailure $
      recover loadWidget (policy Required 3 (recognizeBroken Retry)) $
        withResourceLabelled "widget buffer" (pure ()) (\() → void (bump released)) $ \() →
          bump attempts >>= failAttempt ∷ IO ()
  -- The latest failure is primary, with its own origin.
  failure `shouldBe` WidgetBroken 3
  attemptOrigin context `shouldBe` attemptLabel 3
  length (cleanupFailuresInContext context) `shouldBe` 0
  readIORef released `shouldReturn` 3
  case recoveryHistoryInContext context of
    [history] → do
      historyOperation history `shouldBe` loadWidget
      map attemptNumber (historyAttempts history) `shouldBe` [1, 2]
      map failureOf (historyAttempts history) `shouldBe` [Just (WidgetBroken 1), Just (WidgetBroken 2)]
      map (attemptOrigin . contextOf) (historyAttempts history) `shouldBe` [attemptLabel 1, attemptLabel 2]
      map (length . cleanupFailuresInContext . contextOf) (historyAttempts history) `shouldBe` [0, 0]
    other → expectationFailure ("expected one recovery history, found " <> show other)

testOptionalExhaustion ∷ Expectation
testOptionalExhaustion = do
  attempts ← newCounter
  outcome ←
    recover loadWidget (policy Optional 2 (recognizeBroken Retry)) $
      bump attempts >>= failAttempt ∷ IO (Outcome ())
  case outcome of
    Unavailable reason → do
      unavailableOperation reason `shouldBe` loadWidget
      attemptNumber (unavailableReason reason) `shouldBe` 2
      failureOf (unavailableReason reason) `shouldBe` Just (WidgetBroken 2)
      attemptOrigin (contextOf (unavailableReason reason)) `shouldBe` attemptLabel 2
      map attemptNumber (unavailableEarlier reason) `shouldBe` [1]
      map (attemptOrigin . contextOf) (unavailableEarlier reason) `shouldBe` [attemptLabel 1]
    Available _ → expectationFailure "expected exhausted optional work to be unavailable"
  readIORef attempts `shouldReturn` 2

-- Failures that stop recovery ------------------------------------------------

testUnrecognizedUnchanged ∷ Expectation
testUnrecognizedUnchanged = do
  attempts ← newCounter
  let raise = throwFailure widgets loadWidget [("attempt", "1")] WidgetUnknown
  ExceptionWithContext context failure ←
    expectContext @WidgetFailure $
      recover loadWidget (policy Optional 3 (recognizeBroken Retry)) $
        annotateIO (Marker "kept") (bump attempts >> raise ∷ IO ())
  failure `shouldBe` WidgetUnknown
  attemptOrigin context `shouldBe` attemptLabel 1
  (getExceptionAnnotations context ∷ [Marker]) `shouldBe` [Marker "kept"]
  length (recoveryHistoryInContext context) `shouldBe` 0
  length (handledFailures context) `shouldBe` 0
  readIORef attempts `shouldReturn` 1

testCleanupEvidenceStops ∷ Expectation
testCleanupEvidenceStops = do
  attempts ← newCounter
  classified ← newCounter
  ExceptionWithContext context failure ←
    expectContext @WidgetFailure $
      recover loadWidget (policy Optional 3 (counted classified (recognizeBroken Retry))) $
        withResourceLabelled "widget cache" (pure ()) (\() → ioError (userError "cache release failed")) $ \() →
          bump attempts >>= failAttempt ∷ IO ()
  failure `shouldBe` WidgetBroken 1
  map cleanupFailureLabel (cleanupFailuresInContext context) `shouldBe` ["widget cache"]
  attemptOrigin context `shouldBe` attemptLabel 1
  readIORef classified `shouldReturn` 0
  readIORef attempts `shouldReturn` 1

testClassifierFailure ∷ Expectation
testClassifierFailure = do
  attempts ← newCounter
  classified ← newCounter
  let classifier _ = ioError (userError "classifier broke") ∷ IO (Maybe (Strategy ()))
  ExceptionWithContext context failure ←
    expectContext @IOException $
      recover loadWidget (policy Required 3 (counted classified classifier)) $
        bump attempts >>= failAttempt
  show failure `shouldBe` "user error (classifier broke)"
  readIORef classified `shouldReturn` 1
  readIORef attempts `shouldReturn` 1
  expectHandledAttempt context 1

testWaitFailure ∷ Expectation
testWaitFailure = do
  attempts ← newCounter
  let failing = (policy Required 3 (recognizeBroken Retry)) {policyWait = \_ → ioError (userError "wait broke")}
  ExceptionWithContext context failure ←
    expectContext @IOException $
      recover loadWidget failing (bump attempts >>= failAttempt ∷ IO ())
  show failure `shouldBe` "user error (wait broke)"
  readIORef attempts `shouldReturn` 1
  expectHandledAttempt context 1

-- | The policy failure carries the handled attempt's failure, with its origin,
-- as a 'WhileHandling' annotation.
expectHandledAttempt ∷ ExceptionContext → Int → Expectation
expectHandledAttempt context number =
  case handledFailures context of
    [handled] → do
      fromException handled `shouldBe` Just (WidgetBroken number)
      attemptOrigin (someExceptionContext handled) `shouldBe` attemptLabel number
    other → expectationFailure ("expected one handled failure, found " <> show other)

testEarlyStopUnrecognizedHistory ∷ Expectation
testEarlyStopUnrecognizedHistory = do
  attempts ← newCounter
  ExceptionWithContext context failure ←
    expectContext @WidgetFailure $
      recover loadWidget (policy Optional 3 (recognizeBroken Retry)) $ do
        number ← bump attempts
        if number == 1 then failAttempt 1 else throwIO WidgetUnknown ∷ IO ()
  failure `shouldBe` WidgetUnknown
  readIORef attempts `shouldReturn` 2
  case recoveryHistoryInContext context of
    [history] → do
      map attemptNumber (historyAttempts history) `shouldBe` [1]
      map (attemptOrigin . contextOf) (historyAttempts history) `shouldBe` [attemptLabel 1]
    other → expectationFailure ("expected one recovery history, found " <> show other)

testEarlyStopCleanupHistory ∷ Expectation
testEarlyStopCleanupHistory = do
  attempts ← newCounter
  classified ← newCounter
  ExceptionWithContext context failure ←
    expectContext @SomeException $
      recover loadWidget (policy Optional 2 (counted classified (recognizeBroken Retry))) $ do
        number ← bump attempts
        if number == 1
          then withResourceLabelled "clean" (pure ()) (\() → pure ()) (\() → failAttempt 1)
          else
            withResourceLabelled "widget cache" (pure ()) (\() → ioError (userError "cache release failed")) $ \() →
              failAttempt 2 ∷ IO ()
  fromException failure `shouldBe` Just (WidgetBroken 2)
  map cleanupFailureLabel (cleanupFailuresInContext context) `shouldBe` ["widget cache"]
  -- Only the first attempt was classified: the terminal attempt's failed
  -- cleanup bypassed the classifier, and optional work was not downgraded.
  readIORef classified `shouldReturn` 1
  case recoveryHistory failure of
    [history] → do
      map attemptNumber (historyAttempts history) `shouldBe` [1]
      map (length . cleanupFailuresInContext . contextOf) (historyAttempts history) `shouldBe` [0]
      map (attemptOrigin . contextOf) (historyAttempts history) `shouldBe` [attemptLabel 1]
    other → expectationFailure ("expected one recovery history, found " <> show other)

-- Optional work with a budget of one -----------------------------------------

testBudgetOneUnrecognized ∷ Expectation
testBudgetOneUnrecognized = do
  classified ← newCounter
  outcome ←
    try $
      recover loadWidget (policy Optional 1 (counted classified (recognizeBroken Retry))) (throwIO WidgetUnknown ∷ IO ())
  case outcome of
    Left failure → failure `shouldBe` WidgetUnknown
    Right _ → expectationFailure "expected the unrecognized failure to propagate"
  readIORef classified `shouldReturn` 1

testBudgetOneCleanup ∷ Expectation
testBudgetOneCleanup = do
  classified ← newCounter
  ExceptionWithContext context failure ←
    expectContext @WidgetFailure $
      recover loadWidget (policy Optional 1 (counted classified (recognizeBroken Retry))) $
        withResourceLabelled "widget cache" (pure ()) (\() → ioError (userError "cache release failed")) $ \() →
          failAttempt 1 ∷ IO ()
  failure `shouldBe` WidgetBroken 1
  map cleanupFailureLabel (cleanupFailuresInContext context) `shouldBe` ["widget cache"]
  readIORef classified `shouldReturn` 0

testBudgetOneCancellation ∷ Expectation
testBudgetOneCancellation = do
  classified ← newCounter
  ExceptionWithContext context cancellation ←
    expectContext @SomeException $
      recover loadWidget (policy Optional 1 (counted classified (\_ → pure (Just Retry)))) $
        annotateIO (Marker "blocked") (throwIO ThreadKilled ∷ IO ())
  expectPlainCancellation (ExceptionWithContext context cancellation)
  readIORef classified `shouldReturn` 0

-- Cancellation ---------------------------------------------------------------

testCancelDuringWork ∷ Expectation
testCancelDuringWork = do
  classified ← newCounter
  escaped@(ExceptionWithContext context _) ←
    cancelledScenario $ \blocked →
      recover loadWidget (policy Optional 3 (counted classified (\_ → pure (Just Retry)))) $
        withResourceLabelled "widget cache" (pure ()) (\() → ioError (userError "cache release failed")) $ \() →
          blocked
  expectPlainCancellation escaped
  map cleanupFailureLabel (cleanupFailuresInContext context) `shouldBe` ["widget cache"]
  readIORef classified `shouldReturn` 0

testCancelDuringClassification ∷ Expectation
testCancelDuringClassification = do
  attempts ← newCounter
  escaped ←
    cancelledScenario $ \blocked →
      recover loadWidget (policy Optional 3 (\_ → blocked >> pure (Just Retry))) $
        bump attempts >>= failAttempt
  expectPlainCancellation escaped
  readIORef attempts `shouldReturn` 1

testCancelDuringWait ∷ Expectation
testCancelDuringWait = do
  attempts ← newCounter
  escaped ←
    cancelledScenario $ \blocked →
      recover loadWidget ((policy Optional 3 (recognizeBroken Retry)) {policyWait = const blocked}) $
        bump attempts >>= failAttempt
  expectPlainCancellation escaped
  readIORef attempts `shouldReturn` 1

testCancelDuringFallback ∷ Expectation
testCancelDuringFallback = do
  attempts ← newCounter
  classified ← newCounter
  escaped ←
    cancelledScenario $ \blocked →
      recover loadWidget (policy Optional 3 (counted classified (recognizeBroken (Fallback cachedWidget blocked)))) $
        bump attempts >>= failAttempt
  expectPlainCancellation escaped
  readIORef attempts `shouldReturn` 1
  readIORef classified `shouldReturn` 1
