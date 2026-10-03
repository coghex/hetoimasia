-- | Read-only views of the model: what a subject still owes, a frame's and a
-- target's state, the image a presentation record owns, and the model's usage
-- and live record count.
--
-- Nothing here changes the model or its schedule, so reading a view is never a
-- transition. The work-derived observations the owner schedules from are
-- "Hetoimasia.GPU.Model.Internal.Work" and "Hetoimasia.GPU.Model.Internal.Progress".
module Hetoimasia.GPU.Model.Internal.Observation
  ( HoldView (..)
  , holdView
  , disposalEligible
  , FrameView (..)
  , frameView
  , presentationImage
  , TargetView (..)
  , targetView
  , Usage (..)
  , usage
  , liveRecordCount
  , FramelessView (..)
  , framelessSlots
  ) where

import qualified Data.Map.Strict as Map
import Data.Maybe (mapMaybe)
import qualified Data.Set as Set
import Hetoimasia.GPU.Model.Internal.Accounting (holdsOf, liveFrames)
import Hetoimasia.GPU.Model.Internal.Hold
  ( HoldKind
  , Holds (presentationObligations, recordedReferences, submittedUses)
  , outstandingHolds
  )
import Hetoimasia.GPU.Model.Internal.Identity
import Hetoimasia.GPU.Model.Internal.Records
import Hetoimasia.GPU.Model.Internal.Recovery (RecoveryEpisode (episodeAttempts))
import Hetoimasia.GPU.Model.Internal.Resolve (batchIdOf, resolveFrame, resolvePresentation, resolveSubject, resolveTarget, targetIdOf)
import Hetoimasia.GPU.Model.Internal.State
import Numeric.Natural (Natural)

data HoldView = HoldView
  { viewOutstanding ∷ ![HoldKind]
  , viewRecorded ∷ ![BatchId]
  , viewSubmitted ∷ ![SubmissionId]
  , viewPresentations ∷ ![PresentationId]
  }
  deriving (Eq, Show)

-- | What one subject still owes, or 'Nothing' when it is not this model's.
holdView ∷ HoldSubject → GpuModel → Maybe HoldView
holdView subject model = do
  key ← either (const Nothing) Just (resolveSubject model subject)
  holds ← holdsOf model key
  let owner = case subject of
        GenerationSubject identity → Just (generationTarget identity)
        ResourceSubject _ → Nothing
  pure
    HoldView
      { viewOutstanding = outstandingHolds holds
      , viewRecorded = mapMaybe (\number → Map.lookup number (gpuBatches model) >>= batchIdOf model number) (Set.toList (recordedReferences holds))
      , viewSubmitted = [SubmissionId (gpuSession model) number | number ← Set.toList (submittedUses holds)]
      , viewPresentations =
          [PresentationId target number | Just target ← [owner], number ← Set.toList (presentationObligations holds)]
      }

-- | Whether a live subject has no outstanding holds; an unresolved identity
-- answers 'False'. This is necessary for disposal, but does not check generation
-- phase or an earlier failed disposal. In particular, 'True' does not authorize
-- retrying a failed disposal: the owner's progress and reclamation paths apply
-- those additional checks before offering a subject.
disposalEligible ∷ HoldSubject → GpuModel → Bool
disposalEligible subject model = case holdView subject model of
  Nothing → False
  Just view → null (viewOutstanding view)

data FrameView = FrameView
  { viewFramePhase ∷ !FramePhase
  , viewFrameImage ∷ !(Maybe ImageId)
  , viewFrameSuboptimal ∷ !Bool
  , viewFrameBatches ∷ !Natural
  , viewFrameSubmission ∷ !(Maybe SubmissionId)
  , viewFramePresentation ∷ !(Maybe PresentationId)
  , viewFrameFenceReset ∷ !Bool
  }
  deriving (Eq, Show)

frameView ∷ FrameSlotId → GpuModel → Maybe FrameView
frameView identity model = case resolveFrame model identity of
  Left _ → Nothing
  Right (number, _, frame) → case Map.lookup number (gpuTargets model) of
    Nothing → Nothing
    Just target →
      Just
        FrameView
          { viewFramePhase = framePhase frame
          , viewFrameImage = do
              generation ← frameGeneration frame
              index ← frameImage frame
              pure (ImageId (GenerationId (targetIdOf model number target) generation) index)
          , viewFrameSuboptimal = frameSuboptimal frame
          , viewFrameBatches = fromIntegral (Set.size (frameBatches frame))
          , viewFrameSubmission = SubmissionId (gpuSession model) <$> frameSubmission frame
          , viewFramePresentation = do
              record ← framePoolRecord frame
              entry ← Map.lookup record (targetPool target)
              if poolState entry == PoolEnqueued
                then Just (PresentationId (targetIdOf model number target) record)
                else Nothing
          , viewFrameFenceReset = frameFenceReset frame
          }

-- | The exact image a live presentation record owns. The record outlives its
-- frame, so this answers after the frame slot has been reused and until the
-- retirement — or the explicit settlement of an unpresented frame — that ends it.
presentationImage ∷ PresentationId → GpuModel → Maybe ImageId
presentationImage identity model = case resolvePresentation model identity of
  Left _ → Nothing
  Right (number, _, entry) → do
    generation ← poolGeneration entry
    index ← poolImage entry
    target ← Map.lookup number (gpuTargets model)
    pure (ImageId (GenerationId (targetIdOf model number target) generation) index)

data TargetView = TargetView
  { viewTargetPhase ∷ !TargetPhase
  , viewTargetClass ∷ !TargetClass
  , viewTargetGenerations ∷ !Natural
  , viewTargetActive ∷ !(Maybe GenerationId)
  , viewTargetFrames ∷ !Natural
  , viewTargetPoolRecords ∷ !Natural
  , viewTargetRenderDemand ∷ !Bool
  , viewTargetRetirementDemand ∷ !Bool
  , viewTargetReplacementRequested ∷ !Bool
  , viewTargetRecoveryAttempts ∷ !Natural
  , viewTargetRecoveryEpoch ∷ !Natural
    -- ^ Rises with every admitted attempt and never falls, so two pieces of
    -- health evidence carrying the same epoch were gathered without an attempt
    -- between them.
  , viewTargetCycles ∷ !Natural
    -- ^ Presentation-retirement cycles still waiting for one of their halves.
  }
  deriving (Eq, Show)

targetView ∷ TargetId → GpuModel → Maybe TargetView
targetView identity model = case resolveTarget model identity of
  Left _ → Nothing
  Right (_, target) →
    Just
      TargetView
        { viewTargetPhase = targetPhase target
        , viewTargetClass = targetClassOf target
        , viewTargetGenerations = fromIntegral (Map.size (targetGenerations target))
        , viewTargetActive = GenerationId identity <$> targetActiveGeneration target
        , viewTargetFrames = fromIntegral (Map.size (targetFrames target))
        , viewTargetPoolRecords = fromIntegral (Map.size (targetPool target))
        , viewTargetRenderDemand = targetRenderDemand target && targetPhase target == TargetAdmitted
        , viewTargetRetirementDemand = retirementDemand target
        , viewTargetReplacementRequested =
            targetReplacementRequested target > targetReplacementServed target
        , viewTargetRecoveryAttempts = recoveryAttemptsOf target
        , viewTargetRecoveryEpoch = targetRecoveryEpoch target
        , viewTargetCycles = fromIntegral (Map.size (targetCycles target))
        }

-- | A target owes retirement while it still holds any record at all, whether or
-- not it is suspended. Suspension silences a render deadline; it never silences
-- this.
retirementDemand ∷ Target → Bool
retirementDemand target =
  not (Map.null (targetFrames target))
    || not (Map.null (targetPool target))
    || any ((== GenerationRetired) . generationPhase) (Map.elems (targetGenerations target))

recoveryAttemptsOf ∷ Target → Natural
recoveryAttemptsOf = episodeAttempts . targetRecovery

data Usage = Usage
  { usageTargets ∷ !Natural
  , usageFrames ∷ !Natural
  , usageFramelessSlots ∷ !Natural
    -- ^ The frame-less slots in use, which the frame-less batch budget bounds.
  , usageBatches ∷ !Natural
  , usageSubmissions ∷ !Natural
  , usageBytes ∷ !Natural
  , usageDeviceMemory ∷ !Natural
    -- ^ The part of 'usageBytes' that is device memory the allocator holds.
  , usageObjects ∷ !Natural
  , usageAllocations ∷ !Natural
  , usageResources ∷ !Natural
  }
  deriving (Eq, Show)

usage ∷ GpuModel → Usage
usage model =
  Usage
    { usageTargets = fromIntegral (Map.size (gpuTargets model))
    , usageFrames = liveFrames model
    , usageFramelessSlots = fromIntegral (Map.size (gpuFramelessSlots model))
    , usageBatches = fromIntegral (Map.size (gpuBatches model))
    , usageSubmissions = fromIntegral (Map.size (gpuSubmissions model))
    , usageBytes = gpuBytes model
    , usageDeviceMemory = gpuDeviceMemory model
    , usageObjects = gpuObjects model
    , usageAllocations = fromIntegral (Map.size (gpuAllocations model))
    , usageResources = fromIntegral (Map.size (gpuResources model))
    }

-- | Every record the model is holding. It is bounded by the configuration alone,
-- which is what keeps storage finite when completions never arrive.
liveRecordCount ∷ GpuModel → Natural
liveRecordCount model =
  usageFrames use
    + usageFramelessSlots use
    + usageBatches use
    + usageSubmissions use
    + usageAllocations use
    + usageResources use
    + fromIntegral (sum (map (Map.size . targetGenerations) targets))
    + fromIntegral (sum (map (Map.size . targetPool) targets))
    + fromIntegral (sum (map (Map.size . targetCycles) targets))
    + usageTargets use
  where
    use = usage model
    targets = Map.elems (gpuTargets model)

-- | What one frame-less slot in use holds (GRS-12).
data FramelessView
  = FramelessRecording !BatchId
    -- ^ Its batch, never submitted.
  | FramelessSubmitted !SubmissionId
    -- ^ The submission that consumed its batch, until its completion is
    -- recorded.
  deriving (Eq, Show)

-- | Every frame-less slot in use, by slot.
framelessSlots ∷ GpuModel → [(Natural, FramelessView)]
framelessSlots model =
  [ (slot, view)
  | (slot, held) ← Map.toAscList (gpuFramelessSlots model)
  , Just view ← [viewOf held]
  ]
  where
    viewOf = \case
      SlotRecording number → FramelessRecording <$> (Map.lookup number (gpuBatches model) >>= batchIdOf model number)
      SlotSubmitted number → Just (FramelessSubmitted (SubmissionId (gpuSession model) number))
