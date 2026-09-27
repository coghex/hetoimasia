-- | Worker evidence on a failure that propagated out of a protected drain: what
-- is attached, how it renders, and how a caller reads it back in attachment
-- order.
--
-- This module belongs to the package's private @internal@ sublibrary and is
-- not exposed even there: "Hetoimasia.Foundation.Worker.Internal" re-exports
-- the evidence type and its readers for the rest of the package, and the other
-- worker modules import this module directly. It is private so the annotation
-- entry, 'EvidenceEntry', stays unexported: only this implementation attaches
-- worker evidence.
--
-- It imports "Hetoimasia.Foundation.Worker.Base",
-- "Hetoimasia.Foundation.Worker.Outcome", and the resource family's
-- "Hetoimasia.Foundation.Resource.Cleanup", never group lifecycle, so both
-- "Hetoimasia.Foundation.Worker.Startup" and
-- "Hetoimasia.Foundation.Worker.Group" can attach evidence. It holds no state.
module Hetoimasia.Foundation.Worker.Evidence
  ( WorkerEvidence (..)
  , workerEvidence
  , workerEvidenceInContext
  , attachEvidence
  ) where

import Control.Exception
  ( ExceptionWithContext (ExceptionWithContext)
  , SomeException
  , someExceptionContext
  )
import Control.Exception.Annotation (ExceptionAnnotation (displayExceptionAnnotation))
import Control.Exception.Context
  ( ExceptionContext
  , addExceptionAnnotation
  , getExceptionAnnotations
  )
import Data.List (sortOn)
import qualified Data.Text as Text
import Hetoimasia.Foundation.Resource.Cleanup (CleanupFailure, retainCleanupFailures)
import Hetoimasia.Foundation.Worker.Base (WorkerId (..))
import Hetoimasia.Foundation.Worker.Outcome
  ( Completion (..)
  , GroupReport (..)
  , Result (..)
  , WorkerSummary
  )

-- | Worker evidence attached to a failure that propagated out of a protected
-- drain.
data WorkerEvidence
  = AbandonedStart !WorkerSummary
    -- ^ 'Hetoimasia.Foundation.Worker.startWorkerWith' failed or was
    -- cancelled and drained this worker.
  | GroupExit !GroupReport
    -- ^ 'Hetoimasia.Foundation.Worker.withWorkerGroup' drained its group while
    -- this failure was pending.

-- | Entries carry their attachment position, so reading them back returns
-- attachment order as a property of this module.
data EvidenceEntry = EvidenceEntry !Int !WorkerEvidence

instance ExceptionAnnotation EvidenceEntry where
  displayExceptionAnnotation (EvidenceEntry _ evidence) = case evidence of
    AbandonedStart summary →
      "abandoned worker start: " <> describeSummary summary
    GroupExit report →
      "worker group drained: "
        <> show (length (reportExitedBeforeClosing report))
        <> " exited before closing, "
        <> show (length (reportDrained report))
        <> " drained, "
        <> show (length (reportObservedFailures report))
        <> " observed failures"

describeSummary ∷ WorkerSummary → String
describeSummary summary =
  show (Text.unpack (completionLabel summary))
    <> " #"
    <> show identifier
    <> " "
    <> case completionResult summary of
      Succeeded _ → "succeeded"
      Failed _ → "failed"
      Cancelled _ → "cancelled"
  where
    WorkerId identifier = completionWorker summary

-- | The worker evidence on an exception a caller caught, in attachment order.
workerEvidence ∷ SomeException → [WorkerEvidence]
workerEvidence = workerEvidenceInContext . someExceptionContext

-- | 'workerEvidence' for a caller holding the context directly.
workerEvidenceInContext ∷ ExceptionContext → [WorkerEvidence]
workerEvidenceInContext context =
  [evidence | EvidenceEntry _ evidence ← sortOn position (getExceptionAnnotations context)]
  where
    position (EvidenceEntry index _) = index

-- | Attach worker evidence after any already on the failure, and retain the
-- drained workers' cleanup failures on it.
attachEvidence
  ∷ WorkerEvidence
  → [CleanupFailure]
  → ExceptionWithContext SomeException
  → ExceptionWithContext SomeException
attachEvidence evidence failures (ExceptionWithContext context exception) =
  retainCleanupFailures failures (ExceptionWithContext (addExceptionAnnotation entry context) exception)
  where
    position = length (getExceptionAnnotations context ∷ [EvidenceEntry])
    entry = EvidenceEntry position evidence
