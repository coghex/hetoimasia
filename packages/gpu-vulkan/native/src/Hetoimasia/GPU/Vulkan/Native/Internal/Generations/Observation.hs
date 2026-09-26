-- | What any thread may read of a target's swapchain generations
-- ("Hetoimasia.GPU.Vulkan.Native.Generations"), in 'STM': a coherent view of
-- its condition, its active generation, each generation's standing, plan,
-- handles and uses, and the swapchain result it has yet to reconcile.
--
-- This module only reads the target records of
-- "Hetoimasia.GPU.Vulkan.Native.Internal.Generations.State"; it owns no state
-- of its own, and a view is a copy its reader owns.
module Hetoimasia.GPU.Vulkan.Native.Internal.Generations.Observation
  ( GenerationView (..)
  , TargetGenerationsView (..)
  , readTargetGenerations
  ) where

import Control.Concurrent.STM (STM, readTVar)
import qualified Data.Map.Strict as Map
import Data.Word (Word64)
import Numeric.Natural (Natural)

import Hetoimasia.GPU.Model.Identity (GenerationId, TargetId)
import Hetoimasia.GPU.Vulkan.Native.Internal.Generations.State
  ( GenerationStanding
  , Generations (..)
  , NativeGeneration (..)
  , SwapchainResult
  , TargetCondition
  , TargetRecord (..)
  )
import Hetoimasia.GPU.Vulkan.Native.Presentation (GenerationPlan)

data GenerationView = GenerationView
  { viewGeneration ∷ !GenerationId
  , viewStanding ∷ !GenerationStanding
  , viewPlan ∷ !GenerationPlan
  , viewSwapchain ∷ !(Maybe Word64)
  , viewImages ∷ ![Word64]
  , viewImageViews ∷ ![Word64]
  , viewHandedOver ∷ !Bool
  , viewUses ∷ !Natural
  }
  deriving (Eq, Show)

data TargetGenerationsView = TargetGenerationsView
  { viewCondition ∷ !TargetCondition
  , viewActive ∷ !(Maybe GenerationId)
  , viewGenerations ∷ ![GenerationView]
  , viewConstructions ∷ !Natural
    -- ^ How many constructions have been begun for the target.
  , viewPendingResult ∷ !(Maybe SwapchainResult)
  }
  deriving (Eq, Show)

readTargetGenerations ∷ Generations q inst msgr phys dev → TargetId → STM (Maybe TargetGenerationsView)
readTargetGenerations generations target = do
  record ← Map.lookup target <$> readTVar (generationsTargets generations)
  pure $ flip fmap record $ \entry →
    TargetGenerationsView
      { viewCondition = recordCondition entry
      , viewActive = recordActive entry
      , viewGenerations =
          [ GenerationView
              { viewGeneration = generation
              , viewStanding = genStanding native
              , viewPlan = genPlan native
              , viewSwapchain = genSwapchain native
              , viewImages = genImages native
              , viewImageViews = genViews native
              , viewHandedOver = genHandedOver native
              , viewUses = genUses native
              }
          | (generation, native) ← Map.toAscList (recordGenerations entry)
          ]
      , viewConstructions = recordConstructions entry
      , viewPendingResult = recordResult entry
      }
