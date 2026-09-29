-- | The shared edits and accounting that every transition composes: editing a
-- target, generation, frame or subject's holds in place; charging and releasing
-- object and byte accounting; and freeing a frame slot whose obligations have
-- all ended.
--
-- These are building blocks, not transitions: none of them checks for misuse or
-- applies the scheduling rule, so each transition that composes them remains
-- responsible for both.
module Hetoimasia.GPU.Model.Internal.Accounting
  ( -- * Editing
    editTarget
  , editGeneration
  , editFrame
  , editHolds
  , holdsOf

    -- * Object and byte accounting
  , chargeObjects
  , saturatingMinus
  , releaseObjects
  , releaseBytes
  , liveFrames

    -- * Frame release
  , reservedSubmission
  , settleFrames
  , frameSettled
  ) where

import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Hetoimasia.GPU.Model.Internal.Budget (BudgetKind (ObjectBudget), objectLimit)
import Hetoimasia.GPU.Model.Internal.Hold (Holds)
import Hetoimasia.GPU.Model.Internal.Records
import Hetoimasia.GPU.Model.Internal.State (GpuModel (..))
import Numeric.Natural (Natural)

-- ---------------------------------------------------------------------------
-- Editing

editTarget ∷ Natural → (Target → Target) → GpuModel → GpuModel
editTarget number change model =
  model {gpuTargets = Map.adjust change number (gpuTargets model)}

editGeneration ∷ Natural → Natural → (Generation → Generation) → GpuModel → GpuModel
editGeneration target generation change =
  editTarget target $ \record →
    record {targetGenerations = Map.adjust change generation (targetGenerations record)}

editFrame ∷ Natural → Natural → (Frame → Frame) → GpuModel → GpuModel
editFrame target slot change =
  editTarget target $ \record →
    record {targetFrames = Map.adjust change slot (targetFrames record)}

editHolds ∷ SubjectKey → (Holds → Holds) → GpuModel → GpuModel
editHolds key change model = case key of
  GenerationKey target generation →
    editGeneration target generation (\record → record {generationHolds = change (generationHolds record)}) model
  ResourceKey number generation →
    model
      { gpuResources =
          Map.adjust
            (\record → record {resourceHolds = change (resourceHolds record)})
            (number, generation)
            (gpuResources model)
      }

holdsOf ∷ GpuModel → SubjectKey → Maybe Holds
holdsOf model = \case
  GenerationKey target generation →
    generationHolds
      <$> (Map.lookup target (gpuTargets model) >>= Map.lookup generation . targetGenerations)
  ResourceKey number generation →
    resourceHolds <$> Map.lookup (number, generation) (gpuResources model)

-- ---------------------------------------------------------------------------
-- Object and byte accounting

chargeObjects ∷ Natural → GpuModel → Either BudgetKind GpuModel
chargeObjects count model
  | gpuObjects model + count > objectLimit (gpuBudgets model) = Left ObjectBudget
  | otherwise = Right model {gpuObjects = gpuObjects model + count}

-- | Subtraction that cannot go below zero, for counters the accounting keeps as
-- 'Natural'.
saturatingMinus ∷ Natural → Natural → Natural
saturatingMinus left right
  | right >= left = 0
  | otherwise = left - right

releaseObjects ∷ Natural → GpuModel → GpuModel
releaseObjects count model
  | count >= gpuObjects model = model {gpuObjects = 0}
  | otherwise = model {gpuObjects = gpuObjects model - count}

releaseBytes ∷ Natural → GpuModel → GpuModel
releaseBytes count model
  | count >= gpuBytes model = model {gpuBytes = 0}
  | otherwise = model {gpuBytes = gpuBytes model - count}

liveFrames ∷ GpuModel → Natural
liveFrames = fromIntegral . sum . map (Map.size . targetFrames) . Map.elems . gpuTargets

-- ---------------------------------------------------------------------------
-- Frame release

-- | The object capacity a frame is still holding for a submission record it has
-- not yet used.
reservedSubmission ∷ Frame → Natural
reservedSubmission frame
  | frameSubmissionReserved frame = 1
  | otherwise = 0

-- | Free every named frame whose obligations have all ended.
--
-- A frame slot owns command storage and acquisition synchronization, so it is
-- reusable once its own submission has completed and it holds no unsubmitted
-- recording. Its presentation record is a separate obligation with a separate
-- lifetime: once a presentation is enqueued, that record has taken over the
-- image, belongs to the target's pool and to its generation's holds, and outlives
-- the slot. A frame that was never presented has handed its record to nobody, so
-- it keeps it — and therefore keeps its slot — until the owner supplies explicit
-- settlement evidence.
settleFrames ∷ [(Natural, Natural)] → GpuModel → GpuModel
settleFrames frames model = foldl' settle model frames
  where
    settle current (number, slot) = case Map.lookup number (gpuTargets current) >>= Map.lookup slot . targetFrames of
      Nothing → current
      Just frame
        | frameSettled current frame →
            releaseObjects
              (reservedSubmission frame)
              (editTarget number (\entry → entry {targetFrames = Map.delete slot (targetFrames entry)}) current)
        | otherwise → current

frameSettled ∷ GpuModel → Frame → Bool
frameSettled model frame =
  Set.null (frameBatches frame)
    && submissionGone
    && (framePhase frame == FramePresentationEnqueued || poolGone)
  where
    poolGone = case framePoolRecord frame of
      Nothing → True
      Just record → not (any (Map.member record . targetPool) (Map.elems (gpuTargets model)))
    submissionGone = case frameSubmission frame of
      Nothing → True
      Just number → not (Map.member number (gpuSubmissions model))
