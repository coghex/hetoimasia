-- | Examples for 'Hetoimasia.Foundation.Resource.composeCleanup': the evidence
-- seam for an owner that runs its own release, such as an unrestricted native
-- close that cannot be a scope's release.
--
-- The seam has to give exactly the outcomes the scopes' failure table gives,
-- from failures its caller caught itself, so each example builds the failures
-- with 'tryWithContext', the way a caller does, and reads the result through the
-- public inspection ('cleanupFailures', 'cleanupFailuresInContext'). Expected
-- values are written here from the table, never from the function under test.
module Test.Foundation.Resources.CallerCleanup (spec) where

import Control.Exception
  ( AsyncException (ThreadKilled)
  , ErrorCall (ErrorCall)
  , Exception
  , ExceptionWithContext (ExceptionWithContext)
  , SomeAsyncException
  , SomeException
  , annotateIO
  , fromException
  , rethrowIO
  , throwIO
  , try
  , tryWithContext
  )
import Control.Exception.Annotation (ExceptionAnnotation)
import Control.Exception.Context (ExceptionContext, getExceptionAnnotations)
import Data.Maybe (isJust)
import Data.Text (Text)
import Hetoimasia.Foundation.Resource
  ( CleanupFailure
  , cleanupFailureException
  , cleanupFailureId
  , cleanupFailureLabel
  , cleanupFailures
  , cleanupFailuresInContext
  , composeCleanup
  , withResource
  )
import Test.Hspec (Expectation, Spec, describe, expectationFailure, it, shouldBe, shouldNotBe)

-- | A caller's own annotation, used to prove a failure keeps its context.
newtype Marker = Marker String
  deriving (Eq, Show)

instance ExceptionAnnotation Marker

newtype Broke = Broke String
  deriving (Eq, Show)

instance Exception Broke

spec ∷ Spec
spec = describe "Caller-run cleanup composed with a primary failure" $ do
  it "has nothing to report when nothing failed" $
    composeCleanup Nothing [] >>= (`shouldBeNothing` "an outcome")

  it "returns a primary with no cleanup failure exactly as it was given" $ do
    primary ← caught (Broke "primary") "body"
    composed ← composeCleanup (Just primary) []
    fmap (labelsOf . evidenceOf) composed `shouldBe` Just []
    fmap exceptionOf composed `shouldBe` Just (Just (Broke "primary"))
    fmap markersOf composed `shouldBe` Just ["body"]

  it "keeps the primary's type, value and annotations and retains every cleanup failure beside it, in order" $ do
    primary ← caught (Broke "primary") "body"
    first ← caught (Broke "first") "first context"
    second ← caught (Broke "second") "second context"
    Just composed ← composeCleanup (Just primary) [("finalizer", first), ("release", second)]
    exceptionOf composed `shouldBe` Just (Broke "primary")
    markersOf composed `shouldBe` ["body"]
    labelsOf (evidenceOf composed) `shouldBe` ["finalizer", "release"]
    -- Each failure keeps its own exception and the context it was caught with.
    map causeOf (evidenceOf composed) `shouldBe` [Just (Broke "first"), Just (Broke "second")]
    map contextMarkers (evidenceOf composed) `shouldBe` [["first context"], ["second context"]]

  it "makes the first cleanup failure primary when only cleanup failed, and retains every failure including it" $ do
    first ← caught (Broke "first") "first context"
    second ← caught (Broke "second") "second context"
    Just composed ← composeCleanup Nothing [("finalizer", first), ("release", second)]
    -- The outcome is a failure of the first release's own type and value, and
    -- cleanup evidence a supervisor classifies as cleanup, at once.
    exceptionOf composed `shouldBe` Just (Broke "first")
    labelsOf (evidenceOf composed) `shouldBe` ["finalizer", "release"]
    -- Read back from the exception a caller catches, as a supervisor does.
    raised ← raisedAs composed
    map causeOf (cleanupFailures raised) `shouldBe` [Just (Broke "first"), Just (Broke "second")]

  it "keeps a cancellation primary, and its cleanup evidence still reads as cleanup" $ do
    cancelled ← caught ThreadKilled "cancelled"
    broke ← caught (Broke "close") "close context"
    Just composed ← composeCleanup (Just cancelled) [("close", broke)]
    -- Still an asynchronous exception, which is what makes a worker's outcome
    -- 'Cancelled' rather than 'Failed', and it still carries the evidence a
    -- supervisor reads from its context.
    isAsync composed `shouldBe` True
    exceptionOfAs @AsyncException composed `shouldBe` Just ThreadKilled
    labelsOf (cleanupFailuresInContext (contextOf composed)) `shouldBe` ["close"]

  it "issues each failure a fresh identity in the order they were given, even for one exception recorded twice" $ do
    broke ← caught (Broke "again") "context"
    Just composed ← composeCleanup Nothing [("a", broke), ("b", broke)]
    let identities = map cleanupFailureId (evidenceOf composed)
    length identities `shouldBe` 2
    (identities !! 0) `shouldNotBe` (identities !! 1)
    identities `shouldBe` sortedAscending identities
    labelsOf (evidenceOf composed) `shouldBe` ["a", "b"]

  it "keeps evidence a failure already carried reachable once, and adds the new beside it" $ do
    -- A scope whose release failed leaves its own evidence on what it raised.
    inner ← tryWithContext (withResource (pure ()) (\_ → throwIO (Broke "inner release")) (\_ → throwIO (Broke "inner body")))
    primary ← case inner of
      Left failure → pure failure
      Right () → expectationFailure "the scope did not fail" >> throwIO (Broke "unreachable")
    late ← caught (Broke "late") "late context"
    Just composed ← composeCleanup (Just primary) [("owner close", late)]
    exceptionOf composed `shouldBe` Just (Broke "inner body")
    map causeOf (evidenceOf composed) `shouldBe` [Just (Broke "inner release"), Just (Broke "late")]
    labelsOf (evidenceOf composed) `shouldBe` ["resource release", "owner close"]

  it "adds to the evidence of an enclosing scope in the order observed, innermost first" $ do
    outcome ←
      tryWithContext
        ( withResource (pure ()) (\_ → throwIO (Broke "outer release")) $ \_ → do
            body ← caught (Broke "body") "body"
            inner ← caught (Broke "close") "close"
            composed ← composeCleanup (Just body) [("owner close", inner)]
            maybe (pure ()) rethrowIO composed
        )
    case outcome of
      Right () → expectationFailure "the scopes did not fail"
      Left failure@(ExceptionWithContext _ _) → do
        labelsOf (evidenceOf failure) `shouldBe` ["owner close", "resource release"]
        map causeOf (evidenceOf failure) `shouldBe` [Just (Broke "close"), Just (Broke "outer release")]

-- ---------------------------------------------------------------------------

-- | Catch a failure with the context it was raised with, annotated.
caught ∷ Exception e ⇒ e → String → IO (ExceptionWithContext SomeException)
caught failure note = do
  outcome ← tryWithContext (annotateIO (Marker note) (throwIO failure))
  case outcome of
    Left carried → pure carried
    Right () → throwIO (ErrorCall "the failure was not raised")

shouldBeNothing ∷ Maybe a → String → Expectation
shouldBeNothing found what = case found of
  Nothing → pure ()
  Just _ → expectationFailure ("expected no " <> what)

exceptionOf ∷ Exception e ⇒ ExceptionWithContext SomeException → Maybe e
exceptionOf (ExceptionWithContext _ exception) = fromException exception

exceptionOfAs ∷ ∀ e. Exception e ⇒ ExceptionWithContext SomeException → Maybe e
exceptionOfAs = exceptionOf

isAsync ∷ ExceptionWithContext SomeException → Bool
isAsync (ExceptionWithContext _ exception) = isJust (fromException exception ∷ Maybe SomeAsyncException)

contextOf ∷ ExceptionWithContext SomeException → ExceptionContext
contextOf (ExceptionWithContext context _) = context

-- | Every cleanup failure the exception carries.
evidenceOf ∷ ExceptionWithContext SomeException → [CleanupFailure]
evidenceOf (ExceptionWithContext context _) = cleanupFailuresInContext context

-- | The exception as a caller above the owner catches it.
raisedAs ∷ ExceptionWithContext SomeException → IO SomeException
raisedAs composed = do
  outcome ← try (rethrowIO composed)
  case outcome of
    Left raised → pure raised
    Right () → throwIO (ErrorCall "the composed failure was not raised")

labelsOf ∷ [CleanupFailure] → [Text]
labelsOf = map cleanupFailureLabel

causeOf ∷ Exception e ⇒ CleanupFailure → Maybe e
causeOf failure = case cleanupFailureException failure of
  ExceptionWithContext _ exception → fromException exception

markersOf ∷ ExceptionWithContext SomeException → [String]
markersOf (ExceptionWithContext context _) = [note | Marker note ← getExceptionAnnotations context]

contextMarkers ∷ CleanupFailure → [String]
contextMarkers failure = case cleanupFailureException failure of
  ExceptionWithContext context _ → [note | Marker note ← getExceptionAnnotations context]

sortedAscending ∷ Ord a ⇒ [a] → [a]
sortedAscending [] = []
sortedAscending (x : xs) = x : sortedAscending (filter (> x) xs)
