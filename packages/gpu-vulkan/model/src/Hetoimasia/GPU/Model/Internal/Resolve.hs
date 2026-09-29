-- | Resolving the identities a caller supplies into the model's records, and
-- naming records back as identities.
--
-- This module owns misuse classification: whether an identity is foreign,
-- unknown, stale or already consumed, and which identity kind a compound
-- identity's failure is reported against. It is read-only; the transitions that
-- act on a resolved record live in the modules named for their responsibility.
module Hetoimasia.GPU.Model.Internal.Resolve
  ( -- * Resolution
    resolveTarget
  , resolveGeneration
  , resolveFrame
  , resolveBatch
  , resolveSubmission
  , resolvePresentation
  , resolveResource
  , resolveAllocation
  , resolveSubject

    -- * Naming
  , targetIdOf
  , subjectIdentity
  ) where

import qualified Data.Map.Strict as Map
import Hetoimasia.GPU.Model.Internal.Identity
import Hetoimasia.GPU.Model.Internal.Records
import Hetoimasia.GPU.Model.Internal.Recovery (AllocationAttempt)
import Hetoimasia.GPU.Model.Internal.State (GpuModel (..))
import Numeric.Natural (Natural)

resolveTarget ∷ GpuModel → TargetId → Either Misuse (Natural, Target)
resolveTarget model identity
  | targetSession identity /= gpuSession model = Left (ForeignIdentity TargetIdentity)
  | otherwise = case Map.lookup number (gpuIncarnations model) of
      Nothing → Left (UnknownIdentity TargetIdentity)
      Just highest
        | incarnation > highest → Left (UnknownIdentity TargetIdentity)
        | otherwise → case Map.lookup number (gpuTargets model) of
            Just target
              | targetIncarnationNumber target == incarnation → Right (number, target)
            _ → Left (StaleIdentity TargetIdentity)
  where
    number = targetNumber identity
    incarnation = targetIncarnation identity

-- | Report a compound identity's parent-resolution failure as being about the
-- identity the caller actually supplied. The category is preserved — a foreign
-- parent still means foreign — because it is the category that tells the caller
-- what went wrong; only the kind is corrected, because naming the parent would
-- describe a value the caller never passed.
asKind ∷ IdentityKind → Either Misuse a → Either Misuse a
asKind kind = either (Left . retarget) Right
  where
    retarget = \case
      ForeignIdentity _ → ForeignIdentity kind
      UnknownIdentity _ → UnknownIdentity kind
      StaleIdentity _ → StaleIdentity kind
      AlreadyConsumed _ → AlreadyConsumed kind
      WrongPhase _ → WrongPhase kind
      WrongParent _ → WrongParent kind
      DuplicateSubject _ → DuplicateSubject kind
      other → other

resolveGeneration ∷ GpuModel → GenerationId → Either Misuse (Natural, Natural, Generation)
resolveGeneration model identity = do
  (number, target) ← asKind GenerationIdentity (resolveTarget model (generationTarget identity))
  let generation = generationNumber identity
  case Map.lookup generation (targetGenerations target) of
    Just record → Right (number, generation, record)
    Nothing
      | generation < targetNextGeneration target → Left (StaleIdentity GenerationIdentity)
      | otherwise → Left (UnknownIdentity GenerationIdentity)

resolveFrame ∷ GpuModel → FrameSlotId → Either Misuse (Natural, Natural, Frame)
resolveFrame model identity = do
  (number, target) ← asKind FrameIdentity (resolveTarget model (frameTarget identity))
  let slot = frameSlotNumber identity
      use = frameUse identity
  case Map.lookup slot (targetFrames target) of
    Just frame
      | frameUseNumber frame == use → Right (number, slot, frame)
    _ → case Map.lookup slot (targetSlotUse target) of
      Just highest
        | use <= highest → Left (StaleIdentity FrameIdentity)
      _ → Left (UnknownIdentity FrameIdentity)

resolveBatch ∷ GpuModel → BatchId → Either Misuse (Natural, Batch)
resolveBatch model identity = do
  _ ← asKind BatchIdentity (resolveTarget model (batchTarget identity))
  let number = batchNumber identity
  case Map.lookup number (gpuBatches model) of
    Just record → Right (number, record)
    Nothing
      | number < gpuNextBatch model → Left (AlreadyConsumed BatchIdentity)
      | otherwise → Left (UnknownIdentity BatchIdentity)

resolveSubmission ∷ GpuModel → SubmissionId → Either Misuse (Natural, Submission)
resolveSubmission model identity
  | submissionSession identity /= gpuSession model = Left (ForeignIdentity SubmissionIdentity)
  | otherwise = case Map.lookup number (gpuSubmissions model) of
      Just record → Right (number, record)
      Nothing
        | number < gpuNextSubmission model → Left (AlreadyConsumed SubmissionIdentity)
        | otherwise → Left (UnknownIdentity SubmissionIdentity)
  where
    number = submissionNumber identity

resolvePresentation ∷ GpuModel → PresentationId → Either Misuse (Natural, Natural, PoolRecord)
resolvePresentation model identity = do
  (number, target) ← asKind PresentationIdentity (resolveTarget model (presentationTarget identity))
  let record = presentationNumber identity
  case Map.lookup record (targetPool target) of
    Just entry → Right (number, record, entry)
    Nothing
      | record < gpuNextPresentation model → Left (AlreadyConsumed PresentationIdentity)
      | otherwise → Left (UnknownIdentity PresentationIdentity)

resolveResource ∷ GpuModel → ResourceId → Either Misuse ((Natural, Natural), Resource)
resolveResource model identity
  | resourceSession identity /= gpuSession model = Left (ForeignIdentity ResourceIdentity)
  | otherwise = case Map.lookup number (gpuResourceGenerations model) of
      Nothing
        -- The resource's last generation has been disposed of and its entry
        -- forgotten. The counter still separates a number this session issued
        -- from one it never did.
        | number < gpuNextResource model → Left (StaleIdentity ResourceIdentity)
        | otherwise → Left (UnknownIdentity ResourceIdentity)
      Just current
        | generation > current → Left (UnknownIdentity ResourceIdentity)
        | otherwise → case Map.lookup key (gpuResources model) of
            Just record → Right (key, record)
            Nothing → Left (StaleIdentity ResourceIdentity)
  where
    number = resourceNumber identity
    generation = resourceGeneration identity
    key = (number, generation)

resolveAllocation ∷ GpuModel → AllocationId → Either Misuse (Natural, AllocationAttempt)
resolveAllocation model identity
  | allocationSession identity /= gpuSession model = Left (ForeignIdentity AllocationIdentity)
  | otherwise = case Map.lookup number (gpuAllocations model) of
      Just attempt → Right (number, attempt)
      Nothing
        | number < gpuNextAllocation model → Left (AlreadyConsumed AllocationIdentity)
        | otherwise → Left (UnknownIdentity AllocationIdentity)
  where
    number = allocationNumber identity

resolveSubject ∷ GpuModel → HoldSubject → Either Misuse SubjectKey
resolveSubject model = \case
  GenerationSubject identity → do
    (target, generation, _) ← resolveGeneration model identity
    Right (GenerationKey target generation)
  ResourceSubject identity → do
    (key, _) ← resolveResource model identity
    Right (uncurry ResourceKey key)

-- ---------------------------------------------------------------------------
-- Naming

targetIdOf ∷ GpuModel → Natural → Target → TargetId
targetIdOf model number target =
  TargetId (gpuSession model) number (targetIncarnationNumber target)

subjectIdentity ∷ GpuModel → SubjectKey → Maybe HoldSubject
subjectIdentity model = \case
  GenerationKey target generation → do
    record ← Map.lookup target (gpuTargets model)
    pure (GenerationSubject (GenerationId (targetIdOf model target record) generation))
  ResourceKey number generation →
    Just (ResourceSubject (ResourceId (gpuSession model) number generation))
