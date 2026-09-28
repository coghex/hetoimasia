-- | The swapchain generations' state ("Hetoimasia.GPU.Vulkan.Native.Generations"):
-- the 'Generations' every other part of the implementation works on, the
-- records it holds for each target and each of its generations, the
-- vocabulary the public module exports about them, the failures they raise,
-- and the few helpers every part shares.
--
-- This is the only module that creates state. The other modules under
-- @Hetoimasia.GPU.Vulkan.Native.Internal.Generations@ read and edit the
-- records it defines, each only through the operations the public module's
-- state table assigns to it. Module names below are relative to that prefix.
--
-- = State
--
-- +--------------------+----------------+--------------------------------+--------+---------------------+-----------------------------+
-- | State              | Owner          | Readers and writers            | Thread | Lifetime            | Reset or disposal           |
-- +====================+================+================================+========+=====================+=============================+
-- | Target records     | @State@, which | @State@'s 'trackTarget'        | Owner  | Admission until the | Removed once every          |
-- |                    | creates the    | inserts; @Reconciliation@      |        | target's generations| generation is destroyed     |
-- |                    | map            | advances; @Retirement@ closes  |        | have gone           |                             |
-- |                    |                | and removes; @Step@ and        |        |                     |                             |
-- |                    |                | @Observation@ read             |        |                     |                             |
-- +--------------------+----------------+--------------------------------+--------+---------------------+-----------------------------+
-- | Generation records | @State@, which | @Reconciliation@ inserts and   | Owner  | 'beginGeneration'   | Removed by a destruction    |
-- |                    | defines them   | advances; @Retirement@ retires | (uses: | until destroyed     | that returned; kept         |
-- |                    |                | the active one; @Disposal@     | any)   |                     | uncertain otherwise         |
-- |                    |                | destroys and removes; any      |        |                     |                             |
-- |                    |                | thread holds and ends uses     |        |                     |                             |
-- |                    |                | through @Uses@, in 'STM'       |        |                     |                             |
-- +--------------------+----------------+--------------------------------+--------+---------------------+-----------------------------+
-- | Swapchain results  | @State@, which | Any thread notes through       | Any    | Until the active    | Cleared by the publication  |
-- |                    | defines them   | @Uses@; @Reconciliation@       |        | generation is       | that replaces it            |
-- |                    |                | consumes                       |        | replaced            |                             |
-- +--------------------+----------------+--------------------------------+--------+---------------------+-----------------------------+
module Hetoimasia.GPU.Vulkan.Native.Internal.Generations.State
  ( -- * Records
    GenerationStanding (..)
  , NativeGeneration (..)
  , TargetCondition (..)
  , SwapchainResult (..)
  , TargetRecord (..)

    -- * The generations
  , Generations (..)
  , makeGenerations
  , settlingPeriod
  , trackTarget

    -- * Failures
  , GenerationDestructionFailed (..)
  , GenerationEffectUncertain (..)
  , GenerationsRetained (..)

    -- * Helpers
  , lookupGeneration
  , editGeneration
  , endCpuUse
  , isAsynchronous
  ) where

import Control.Concurrent.STM (STM, TVar, modifyTVar', newTVarIO, readTVar)
import Control.Exception (Exception (displayException), SomeAsyncException, SomeException, fromException)
import Control.Monad (unless)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe (isJust)
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Word (Word64)
import Numeric.Natural (Natural)

import Hetoimasia.Foundation.Time
  ( Duration
  , DurationRequirement (RequirePositive)
  , Instant
  , durationFromNanoseconds
  , minimumPositiveDuration
  )
import Hetoimasia.GPU.Model (Outcome (..), endGenerationCpuUse)
import Hetoimasia.GPU.Model.Budget (BudgetKind)
import Hetoimasia.GPU.Model.Identity (GenerationId, TargetClass, TargetId, generationTarget)
import Hetoimasia.GPU.Vulkan.Native.Presentation
  ( CaptureUsage (..)
  , GenerationPlan
  , PresentationGap
  , SurfaceExtent
  , Suspension
  , TargetGeometry
  )
import Hetoimasia.GPU.Vulkan.Native.Roots (Roots, stateRootsModel)

-- ---------------------------------------------------------------------------
-- Records

-- | Where one generation stands in this module's own record.
data GenerationStanding
  = GenerationBuilding
    -- ^ Its construction is in progress, or was interrupted before it
    -- settled.
  | GenerationPresenting
    -- ^ The target's active generation.
  | GenerationRetiredHeld
    -- ^ Retired: nothing is acquired from it again, and it is destroyed once
    -- the model reports every hold on it ended.
  | GenerationDestroyedPending
    -- ^ Destroyed natively; the model has not yet recorded the disposal.
  | GenerationUncertain !Text
    -- ^ A destruction, or the bookkeeping of an effect, did not complete. It is
    -- never offered again, and everything above it is retained.
  deriving (Eq, Show)

data NativeGeneration = NativeGeneration
  { genPlan ∷ !GenerationPlan
  , genStanding ∷ !GenerationStanding
  , genSwapchain ∷ !(Maybe Word64)
  , genImages ∷ ![Word64]
  , genViews ∷ ![Word64]
    -- ^ In creation order; destroyed in reverse.
  , genHandedOver ∷ !Bool
    -- ^ Passed as @oldSwapchain@, which Vulkan retires whether or not the
    -- creation it was passed to succeeded.
  , genUses ∷ !Natural
  , genCpuEnded ∷ !Bool
  , genGeometry ∷ !TargetGeometry
    -- ^ The geometry it was planned from.
  }

-- | What a target's generations are doing, as any thread may read it.
data TargetCondition
  = AwaitingGeneration
    -- ^ Tracked, and nothing has been constructed yet.
  | Presenting
  | Suspended !Suspension
    -- ^ No usable extent now. Acquisition is suspended; this is not a failure.
  | Settling !Instant
    -- ^ The geometry moved; the replacement coalesces every later move until
    -- this instant, and the active generation, if there is one, keeps
    -- presenting meanwhile.
  | Backpressured !BudgetKind
    -- ^ The replacement cannot fit its budget yet. The active generation, if
    -- there is one, keeps presenting; without one rendering is paused. Every
    -- other target and the owner carry on.
  | ConstructionFailed !Text
    -- ^ The last construction failed. The target has no active generation,
    -- and the next construction is a fresh one and a recovery attempt.
  | RecoveryWaiting !Instant
    -- ^ The model's episode admits the next attempt at this instant.
  | RecoveryUnscheduled
    -- ^ The delay the episode owes before its next attempt does not fit the
    -- clock's representation, so no attempt can be admitted without shortening
    -- it. Nothing is built and no step is asked for; the target waits,
    -- unscheduled, until it is closed.
  | RecoverySpent
    -- ^ The episode is spent, or the session's device cannot present to the
    -- surface recovery replaced; the model escalated through the target's
    -- designation. Its retired generations still go as their holds end.
  | SurfaceLost
    -- ^ The target's surface was lost (VK-14). Its active generation is
    -- retired, nothing is acquired, and once every generation of it has been
    -- destroyed the surface is released and a replacement asked for, as a
    -- recovery attempt of the target's episode.
  | SurfaceReplacing
    -- ^ A recovery attempt the episode admitted is waiting for a replacement
    -- surface on the same window.
  | PresentationUnsupported ![PresentationGap]
    -- ^ A structured target failure: the surface cannot serve the profile.
  | Closing
  deriving (Eq, Show)

-- | What a swapchain call on a target's active generation answered.
data SwapchainResult
  = SwapchainOutOfDate
  | SwapchainSuboptimal
  | SwapchainSurfaceLost
    -- ^ @VK_ERROR_SURFACE_LOST_KHR@: the surface itself must be replaced
    -- (VK-14), which outranks any other result.
  deriving (Eq, Show)

data TargetRecord = TargetRecord
  { recordSurface ∷ !Word64
  , recordClass ∷ !TargetClass
  , recordGenerations ∷ !(Map GenerationId NativeGeneration)
  , recordActive ∷ !(Maybe GenerationId)
  , recordCondition ∷ !TargetCondition
  , recordSettling ∷ !(Maybe (SurfaceExtent, TargetGeometry, Instant))
    -- ^ The newest extent a replacement would be built at, the observed
    -- geometry it was planned from, and when the move they belong to was
    -- first seen.
  , recordResult ∷ !(Maybe SwapchainResult)
  , recordResultUnseen ∷ !Bool
    -- ^ A result was reported, or a replacement surface installed, since the
    -- target's last reconciliation, so a step is owed at once.
  , recordLastPlanned ∷ !(Maybe (SurfaceExtent, TargetGeometry))
    -- ^ The extent and observed geometry of the last construction begun.
  , recordFailed ∷ !Bool
    -- ^ The last construction failed, so the next is a recovery attempt.
  , recordRecovering ∷ !Bool
    -- ^ A recovery attempt the model admitted is outstanding.
  , recordConstructions ∷ !Natural
  , recordSurfaceLost ∷ !Bool
    -- ^ The surface 'recordSurface' names was lost (VK-14): nothing is planned
    -- or built on it, and it is released and replaced.
  }

-- | The generations of one session's targets, over its roots.
data Generations q inst msgr phys dev = Generations
  { generationsRoots ∷ !(Roots q inst msgr phys dev)
  , generationsTargets ∷ !(TVar (Map TargetId TargetRecord))
  , generationsAfterAdmission ∷ GenerationId → IO ()
    -- ^ The examples' seam: runs right after the model admitted a candidate,
    -- inside the construction's masked settlement. Production runs nothing.
  , generationsCapture ∷ !CaptureUsage
  , generationsCursor ∷ !(TVar Natural)
    -- ^ Where the owner's next step starts among the targets when it destroys
    -- retired generations, so a step's bounded disposal reaches every target
    -- in turn.
  }

-- | The generations' state, with the examples' seam and the capture usage.
-- The public constructors are "Hetoimasia.GPU.Vulkan.Native.Internal.Generations.Disposal"'s,
-- which also register the generations' disposer with the roots.
makeGenerations ∷ (GenerationId → IO ()) → CaptureUsage → Roots q inst msgr phys dev → IO (Generations q inst msgr phys dev)
makeGenerations hook capture roots = (\targets → Generations roots targets hook capture) <$> newTVarIO Map.empty <*> newTVarIO 0

-- | How long a move is coalesced, from when it was first seen, before its
-- replacement is built from the newest geometry: 16 ms. It bounds how often a
-- continuous resize rebuilds, not how long the geometry must stay quiet.
settlingPeriod ∷ Duration
settlingPeriod = either (const minimumPositiveDuration) id (durationFromNanoseconds RequirePositive 16000000)

-- | Begin tracking a target the roots admitted, on the surface they hold for
-- it. Nothing is constructed until a step finds it eligible.
trackTarget ∷ Generations q inst msgr phys dev → TargetId → TargetClass → Word64 → STM ()
trackTarget generations target classification surface =
  modifyTVar' (generationsTargets generations) $
    Map.insertWith
      (\_ existing → existing)
      target
      TargetRecord
        { recordSurface = surface
        , recordClass = classification
        , recordGenerations = Map.empty
        , recordActive = Nothing
        , recordCondition = AwaitingGeneration
        , recordSettling = Nothing
        , recordResult = Nothing
        , recordResultUnseen = False
        , recordLastPlanned = Nothing
        , recordFailed = False
        , recordRecovering = False
        , recordConstructions = 0
        , recordSurfaceLost = False
        }

-- ---------------------------------------------------------------------------
-- Failures

-- | A generation's destruction raised. It is retained, never attempted again,
-- and the session has failed with 'CleanupFailed'.
data GenerationDestructionFailed = GenerationDestructionFailed !GenerationId !Text
  deriving (Eq, Show)

instance Exception GenerationDestructionFailed where
  displayException (GenerationDestructionFailed generation reason) =
    "destroying " <> show generation <> " did not complete: " <> Text.unpack reason

-- | A native effect happened and its bookkeeping could not be committed. The
-- result is retained, admission has stopped and the session has failed.
data GenerationEffectUncertain = GenerationEffectUncertain !GenerationId !Text
  deriving (Eq, Show)

instance Exception GenerationEffectUncertain where
  displayException (GenerationEffectUncertain generation reason) =
    "the outcome of " <> show generation <> " is uncertain: " <> Text.unpack reason

-- | A target's retirement found generations it could not destroy: holds that
-- have not ended, or a destruction that was uncertain. They, the surface and
-- everything above them are retained.
data GenerationsRetained = GenerationsRetained !TargetId ![GenerationId]
  deriving (Eq, Show)

instance Exception GenerationsRetained where
  displayException (GenerationsRetained target retained) =
    "the swapchain generations of " <> show target <> " are retained: " <> show retained

-- ---------------------------------------------------------------------------
-- Helpers

lookupGeneration ∷ Generations q inst msgr phys dev → GenerationId → STM (Maybe NativeGeneration)
lookupGeneration generations generation =
  (\records → Map.lookup (generationTarget generation) records >>= Map.lookup generation . recordGenerations)
    <$> readTVar (generationsTargets generations)

editGeneration ∷ Generations q inst msgr phys dev → GenerationId → (NativeGeneration → NativeGeneration) → STM ()
editGeneration generations generation edit =
  modifyTVar' (generationsTargets generations) $
    Map.adjust (\record → record {recordGenerations = Map.adjust edit generation (recordGenerations record)}) (generationTarget generation)

-- | Certify in the model that nothing can record this generation again.
endCpuUse ∷ Generations q inst msgr phys dev → GenerationId → STM ()
endCpuUse generations generation = do
  native ← lookupGeneration generations generation
  unless (maybe True genCpuEnded native) $ do
    stateRootsModel (generationsRoots generations) $ \model → case endGenerationCpuUse generation model of
      Admitted next → ((), next)
      _ → ((), model)
    editGeneration generations generation (\entry → entry {genCpuEnded = True})

isAsynchronous ∷ SomeException → Bool
isAsynchronous exception = isJust (fromException exception ∷ Maybe SomeAsyncException)
