-- | Disposal of settled subjects: removing one and giving back exactly its
-- accounting, remembering a failed disposal so it is never offered again, and
-- the bounded reclamation pass.
--
-- Nothing here decides which subjects may be offered; that is the one rule in
-- "Hetoimasia.GPU.Model.Internal.Work", and both this module's reclamation pass and owner
-- progress in "Hetoimasia.GPU.Model.Internal.Progress" choose subjects through it.
module Hetoimasia.GPU.Model.Internal.Disposal
  ( dispose
  , rememberFailure
  , rotated
  , ReclaimReport (..)
  , reclaimPass
  ) where

import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Hetoimasia.GPU.Model.Internal.Accounting (editTarget, releaseBytes, releaseObjects)
import Hetoimasia.GPU.Model.Internal.Budget (reclaimExaminationLimit)
import Hetoimasia.GPU.Model.Internal.Completion (DisposalResult (..), EvidenceSource (..))
import Hetoimasia.GPU.Model.Internal.Identity
import Hetoimasia.GPU.Model.Internal.Records
import Hetoimasia.GPU.Model.Internal.Recovery (AllocationAttempt (attemptFailed, attemptReclaimedSince, attemptRetrySpent))
import Hetoimasia.GPU.Model.Internal.Resolve (subjectIdentity)
import Hetoimasia.GPU.Model.Internal.Session (escalateSession)
import Hetoimasia.GPU.Model.Internal.State
import Hetoimasia.GPU.Model.Internal.Work (allSubjects, eligible)
import Numeric.Natural (Natural)

-- | Remove a settled subject and give back exactly the accounting it held.
-- Nothing here is reachable for a subject with an outstanding hold: only owner
-- progress's @nextAction@ and 'reclaimPass' choose subjects, and both filter on
-- 'eligible' first, which requires 'Hetoimasia.GPU.Model.Internal.Hold.holdsSettled'.
dispose ∷ SubjectKey → GpuModel → GpuModel
dispose key model = case key of
  GenerationKey number generation → case Map.lookup number (gpuTargets model) >>= Map.lookup generation . targetGenerations of
    Nothing → model
    Just record →
      editTarget
        number
        (\entry → entry {targetGenerations = Map.delete generation (targetGenerations entry)})
        (releaseObjects (generationReservedObjects record) model)
  ResourceKey logical generation → case Map.lookup (logical, generation) (gpuResources model) of
    Nothing → model
    Just record →
      let remaining = Map.delete (logical, generation) (gpuResources model)
          -- Once no generation of a logical resource is left, its current-
          -- generation entry is history rather than state, and keeping it would
          -- grow a map that nothing accounts for. A retained identity for it is
          -- still classified as stale, by the monotonic resource counter rather
          -- than by remembering the resource.
          generations
            | any ((== logical) . fst) (Map.keys remaining) = gpuResourceGenerations model
            | otherwise = Map.delete logical (gpuResourceGenerations model)
       in releaseBytes
            (resourceBytes record)
            ( releaseObjects
                (resourceObjects record)
                model {gpuResources = remaining, gpuResourceGenerations = generations}
            )

-- | Record that a disposal of this subject failed, so it is never offered for
-- disposal again. The subject and its accounting stay exactly where they are.
rememberFailure ∷ SubjectKey → GpuModel → GpuModel
rememberFailure key model =
  model {gpuDisposalFailures = Set.insert key (gpuDisposalFailures model)}

-- | Start a list at the cursor's position, wrapping round, so that successive
-- owner turns and reclamation passes each begin where the last one moved on to.
rotated ∷ Natural → [a] → [a]
rotated _ [] = []
rotated cursor entries = drop offset entries ++ take offset entries
  where
    offset = fromIntegral (cursor `mod` fromIntegral (length entries))

data ReclaimReport = ReclaimReport
  { reclaimExamined ∷ !Natural
  , reclaimDisposed ∷ ![HoldSubject]
  , reclaimFailures ∷ ![HoldSubject]
  }
  deriving (Eq, Show)

-- | Examine a bounded window of generation and managed-resource records and
-- offer its eligible subjects for disposal. It examines at most the configured
-- number of records, waits for nothing, and counts progress only where a
-- disposal actually completed. Finding eligible work, or asking for a disposal
-- that then failed, is not progress and unlocks no retry.
reclaimPass ∷ EvidenceSource → GpuModel → (GpuModel, ReclaimReport)
reclaimPass source model = (advanced, report)
  where
    limit = fromIntegral (reclaimExaminationLimit (gpuBudgets model))
    -- The window is taken from all generation and managed-resource records,
    -- not just the eligible ones: deciding that a record is ineligible is itself
    -- an examination. Filtering first would let a pass read every subject while
    -- reporting that it read almost nothing.
    examined = take limit (rotated (gpuReclaimCursor model) (allSubjects model))
    candidates = filter (eligible model) examined
    (worked, disposedSubjects, failedSubjects) = foldl' step (model, [], []) candidates
    step (current, disposedSoFar, failed) key = case subjectIdentity current key of
      Nothing → (current, disposedSoFar, failed)
      Just subject → case disposalEvidence source subject of
        DisposalRefused → (current, disposedSoFar, failed)
        DisposalCompleted → (dispose key current, subject : disposedSoFar, failed)
        DisposalFailed → (escalateSession CleanupFailed (rememberFailure key current), disposedSoFar, subject : failed)
    advanced = marked {gpuReclaimCursor = gpuReclaimCursor marked + fromIntegral (length examined)}
    marked
      | null disposedSubjects = worked
      | otherwise = worked {gpuAllocations = Map.map credit (gpuAllocations worked)}
    credit attempt
      | attemptFailed attempt && not (attemptRetrySpent attempt) = attempt {attemptReclaimedSince = True}
      | otherwise = attempt
    report =
      ReclaimReport
        { reclaimExamined = fromIntegral (length examined)
        , reclaimDisposed = reverse disposedSubjects
        , reclaimFailures = reverse failedSubjects
        }
