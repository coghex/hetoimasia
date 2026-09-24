-- | The lifetime's outcome selection: which failure is primary, and the
-- finalization evidence kept beside it.
--
-- Driven directly through the package's private selection, because a failure
-- while the lifetime's worker group closes arrives only after the worker is
-- terminal, where no public coordination point exists and only timing could
-- place one. The lifetime calls exactly this selection, so what holds here is
-- what it rethrows.
module Test.GPU.Vulkan.Diagnostics.Outcome (spec) where

import Control.Exception
  ( Exception
  , ExceptionWithContext (ExceptionWithContext)
  , SomeException
  , fromException
  , toException
  )
import Control.Exception.Context (addExceptionAnnotation, emptyExceptionContext, getExceptionAnnotations)
import Control.Monad (forM_)
import Test.Hspec (Spec, describe, expectationFailure, it, shouldBe)

import Hetoimasia.GPU.Vulkan.Diagnostics (FinalizationEvidence (..), finalizationEvidenceInContext)
import Hetoimasia.GPU.Vulkan.Diagnostics.Internal.Outcome (selectOutcome)
import Test.GPU.Vulkan.Diagnostics.Support (BodyMarker (..), TaggedFailure (..))

-- | A failure standing for one input to the selection.
newtype Labelled = Labelled String
  deriving (Eq, Show)

instance Exception Labelled

-- | A failure as the lifetime would have caught it: its own context carries a
-- marker naming it.
caught ∷ Exception e ⇒ String → e → ExceptionWithContext SomeException
caught marker failure =
  ExceptionWithContext (addExceptionAnnotation (BodyMarker marker) emptyExceptionContext) (toException failure)

labelled ∷ String → ExceptionWithContext SomeException
labelled label = caught label (Labelled label)

-- | What an outcome says, in labels: the primary, the markers on its context,
-- and the labels of the cancellation and the group-closing failure beside it.
data Described = Described
  { describedPrimary ∷ String
  , describedMarkers ∷ [String]
  , describedCancellation ∷ Maybe String
  , describedGroupFailure ∷ Maybe String
  }
  deriving (Eq, Show)

describeOutcome ∷ Either (ExceptionWithContext SomeException) () → Described
describeOutcome = \case
  Right () → Described "result" [] Nothing Nothing
  Left (ExceptionWithContext context failure) →
    Described
      { describedPrimary = labelOf failure
      , describedMarkers = markers context
      , describedCancellation = evidence evidenceCancellation context
      , describedGroupFailure = evidence evidenceGroupFailure context
      }
  where
    labelOf failure = maybe "unlabelled" (\(Labelled label) → label) (fromException failure)
    markers context = [marker | BodyMarker marker ← getExceptionAnnotations context]
    evidence field context = do
      found ← finalizationEvidenceInContext context
      ExceptionWithContext _ failure ← field found
      pure (labelOf failure)

spec ∷ Spec
spec = describe "Outcome" $ do
  it "keeps a failed body primary over a group-closing failure, with the group's own context beside it" $ do
    let body = caught "the body's own context" (TaggedFailure 7)
        grouped = caught "the group's own context" (Labelled "group closing")
    case selectOutcome Nothing (Just grouped) (Left body ∷ Either (ExceptionWithContext SomeException) ()) of
      Right () → expectationFailure "the body's failure was lost"
      Left (ExceptionWithContext context failure) → do
        fromException failure `shouldBe` Just (TaggedFailure 7)
        getExceptionAnnotations context `shouldBe` [BodyMarker "the body's own context"]
        case finalizationEvidenceInContext context of
          Nothing → expectationFailure "the group-closing failure was dropped"
          Just found → do
            fmap (const ()) (evidenceCancellation found) `shouldBe` Nothing
            case evidenceGroupFailure found of
              Nothing → expectationFailure "the group-closing failure was dropped"
              Just (ExceptionWithContext groupContext groupFailure) → do
                fromException groupFailure `shouldBe` Just (Labelled "group closing")
                getExceptionAnnotations groupContext `shouldBe` [BodyMarker "the group's own context"]

  it "follows the documented precedence for every combination" $ do
    let cancellation = Just (labelled "cancellation")
        grouped = Just (labelled "group")
        body = Left (labelled "body")
        rows =
          [ (Nothing, Nothing, Right (), Described "result" [] Nothing Nothing)
          , (cancellation, Nothing, Right (), Described "cancellation" ["cancellation"] Nothing Nothing)
          , (Nothing, grouped, Right (), Described "group" ["group"] Nothing Nothing)
          , (cancellation, grouped, Right (), Described "cancellation" ["cancellation"] Nothing Nothing)
          , (Nothing, Nothing, body, Described "body" ["body"] Nothing Nothing)
          , (cancellation, Nothing, body, Described "body" ["body"] (Just "cancellation") Nothing)
          , (Nothing, grouped, body, Described "body" ["body"] Nothing (Just "group"))
          , (cancellation, grouped, body, Described "body" ["body"] (Just "cancellation") (Just "group"))
          ]
    forM_ rows $ \(pending, late, outcome, expected) →
      describeOutcome (selectOutcome pending late outcome) `shouldBe` expected
