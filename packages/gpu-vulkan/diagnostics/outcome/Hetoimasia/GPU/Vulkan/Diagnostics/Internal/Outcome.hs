-- | Which failure a diagnostic lifetime rethrows, and the evidence it keeps
-- beside it.
--
-- Pure and private, so the lifetime and this package's own suite share one
-- selection, and the suite can drive combinations — a failed body beside a
-- worker-group closing failure — that no public interleaving can coordinate
-- without timing. The public module re-exports 'FinalizationEvidence' and reads
-- it back from an exception's context.
module Hetoimasia.GPU.Vulkan.Diagnostics.Internal.Outcome
  ( FinalizationEvidence (..)
  , selectOutcome
  ) where

import Control.Exception (ExceptionWithContext (ExceptionWithContext), SomeException, displayException)
import Control.Exception.Annotation (ExceptionAnnotation (displayExceptionAnnotation))
import Control.Exception.Context (addExceptionAnnotation)
import Data.List (intercalate)

-- | What finalization observed beside a body failure that stayed primary.
--
-- Each field is the exception exactly as the lifetime caught it, context
-- included, so a group-closing failure's own annotations stay reachable. At
-- most one of each is kept: later cancellations during the same finalization
-- are not retained.
data FinalizationEvidence = FinalizationEvidence
  { evidenceCancellation ∷ !(Maybe (ExceptionWithContext SomeException))
    -- ^ The first cancellation delivered while the lifetime waited for its
    -- worker's final drain.
  , evidenceGroupFailure ∷ !(Maybe (ExceptionWithContext SomeException))
    -- ^ A failure raised while the lifetime's own worker group closed.
  }
  deriving (Show)

instance ExceptionAnnotation FinalizationEvidence where
  displayExceptionAnnotation evidence =
    "diagnostic finalization also observed: "
      <> intercalate
        ", "
        ( [ "cancellation (" <> describe failure <> ")"
          | Just failure ← [evidenceCancellation evidence]
          ]
            <> [ "group closing failure (" <> describe failure <> ")"
               | Just failure ← [evidenceGroupFailure evidence]
               ]
        )
    where
      describe (ExceptionWithContext _ failure) = displayException failure

-- | Choose the lifetime's outcome from the first cancellation delivered during
-- finalization, a failure raised while its worker group closed, and the body's
-- own outcome.
--
-- A body failure, a body cancellation included, is always primary: it keeps its
-- own type, value and context, and whatever finalization observed is added to
-- that context as 'FinalizationEvidence'. A body that succeeded yields the
-- cancellation first, then the group-closing failure, then its result.
selectOutcome
  ∷ Maybe (ExceptionWithContext SomeException)
  → Maybe (ExceptionWithContext SomeException)
  → Either (ExceptionWithContext SomeException) a
  → Either (ExceptionWithContext SomeException) a
selectOutcome cancellation groupFailure = \case
  Left (ExceptionWithContext context failure) → Left (ExceptionWithContext (withEvidence context) failure)
  Right result → maybe (Right result) Left (maybe groupFailure Just cancellation)
  where
    withEvidence context = case (cancellation, groupFailure) of
      (Nothing, Nothing) → context
      _ → addExceptionAnnotation (FinalizationEvidence cancellation groupFailure) context
