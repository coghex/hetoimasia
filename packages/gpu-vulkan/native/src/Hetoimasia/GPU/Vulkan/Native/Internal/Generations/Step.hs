-- | The graphics owner's step over every tracked target
-- ("Hetoimasia.GPU.Vulkan.Native.Generations"): disposal of whatever has
-- become disposable, then each named target's reconciliation, then one model
-- progress turn; and the earliest instant the next step is owed.
--
-- This module sequences "Hetoimasia.GPU.Vulkan.Native.Internal.Generations.Disposal"
-- and "Hetoimasia.GPU.Vulkan.Native.Internal.Generations.Reconciliation", and
-- reads the target records of
-- "Hetoimasia.GPU.Vulkan.Native.Internal.Generations.State" to compute the
-- deadline; it owns no state of its own and writes none directly.
module Hetoimasia.GPU.Vulkan.Native.Internal.Generations.Step
  ( StepSummary (..)
  , stepGenerations
  , generationsDeadline
  ) where

import Control.Concurrent.STM (STM, atomically, readTVar, readTVarIO)
import Control.Exception (throwIO)
import Control.Monad (forM)
import Data.Foldable (for_)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe (mapMaybe)

import Hetoimasia.Foundation.Time (Instant)
import Hetoimasia.GPU.Model
  ( DisposalResult (..)
  , GpuModel
  , NextTurn (..)
  , SessionState (..)
  , TargetPhase (..)
  , TargetView (..)
  , nextDeadline
  , sessionState
  , targetView
  )
import Hetoimasia.GPU.Model.Identity (GenerationId, TargetId)
import Hetoimasia.GPU.Vulkan.Native.Internal.Generations.Disposal (disposeEligible, progress)
import Hetoimasia.GPU.Vulkan.Native.Internal.Generations.Reconciliation (reconcile)
import Hetoimasia.GPU.Vulkan.Native.Internal.Generations.State (Generations (..), TargetCondition (..), TargetRecord (..))
import Hetoimasia.GPU.Vulkan.Native.Internal.Generations.Surface (releaseLostSurfaces)
import Hetoimasia.GPU.Vulkan.Native.Presentation (TargetGeometry)
import Hetoimasia.GPU.Vulkan.Native.Roots (stateRootsModel)

-- | What one step did.
data StepSummary = StepSummary
  { summaryConstructed ∷ ![GenerationId]
  , summaryDestroyed ∷ ![GenerationId]
  , summaryAdvanced ∷ !Bool
  , summarySurfacesWanted ∷ ![TargetId]
    -- ^ Targets whose lost surface this step released, each with a recovery
    -- attempt the episode just admitted, now wanting a replacement surface on
    -- the same window ('Hetoimasia.GPU.Vulkan.Native.Generations.offerReplacementSurface').
  }
  deriving (Eq, Show)

-- | One step over every tracked target, on the owner's thread: destroy what
-- has become disposable, then reconcile each target with its latest geometry,
-- then release every lost surface whose generations have all gone and ask its
-- episode for an attempt.
--
-- The geometry of a target the caller does not name is left as the step last
-- found it. A destruction that raised is reported, after the whole pass, as
-- 'Hetoimasia.GPU.Vulkan.Native.Generations.GenerationDestructionFailed'.
stepGenerations ∷ Generations q inst msgr phys dev → Instant → Map TargetId TargetGeometry → IO StepSummary
stepGenerations generations now geometries = do
  (destroyed, failure) ← disposeEligible generations now Nothing
  for_ failure throwIO
  targets ← Map.keys <$> readTVarIO (generationsTargets generations)
  built ← forM targets $ \target → case Map.lookup target geometries of
    Nothing → pure Nothing
    Just geometry → reconcile generations now target geometry
  wanted ← releaseLostSurfaces generations now
  -- One progress turn per step, so the model's backoff is anchored to this
  -- step's instant rather than asking for a turn now for ever.
  _ ← atomically (progress generations now (const DisposalRefused))
  let constructed = [generation | Just generation ← built]
  pure (StepSummary constructed destroyed (not (null constructed && null destroyed && null wanted)) wanted)

-- | The earliest instant a step is owed: a swapchain result not yet
-- reconciled, a settling replacement, a deferred recovery attempt, a lost
-- surface whose generations have all gone and which may now be released, or
-- the model's own schedule. 'Left' means a step is owed now.
generationsDeadline ∷ Generations q inst msgr phys dev → STM (Maybe (Either () Instant))
generationsDeadline generations = do
  records' ← readTVar (generationsTargets generations)
  let records = Map.elems records'
  model ← stateRootsModel (generationsRoots generations) (\model → (model, model))
  let unseen = any recordResultUnseen records || any (releasable model) (Map.toList records')
      own =
        mapMaybe
          ( \record → case recordCondition record of
              Settling at → Just at
              RecoveryWaiting at → Just at
              _ → Nothing
          )
          records
      modelled = case nextDeadline model of
        TurnNow → Just (Left ())
        TurnAt at → Just (Right at)
        _ → Nothing
      candidates = [Left () | unseen] <> map Right own <> maybe [] pure modelled
  pure $ case candidates of
    [] → Nothing
    _ | any isNow candidates → Just (Left ())
    _ → Just (Right (minimum [at | Right at ← candidates]))
  where
    isNow = either (const True) (const False)

-- | Whether a lost surface can be released, and an attempt asked for, at the
-- next step: nothing of it remains, nothing is outstanding or scheduled, and
-- the target is open in a running session. Anything else waits for its own
-- evidence or deadline, so this never asks for a step it would not take.
releasable ∷ GpuModel → (TargetId, TargetRecord) → Bool
releasable model (target, record) =
  recordSurfaceLost record
    && Map.null (recordGenerations record)
    && recordCondition record == SurfaceLost
    && sessionState model == SessionRunning
    && maybe False ((`notElem` [TargetRetiring, TargetUnavailable]) . viewTargetPhase) (targetView target model)
