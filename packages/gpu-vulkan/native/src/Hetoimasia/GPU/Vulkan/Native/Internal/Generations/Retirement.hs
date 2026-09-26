-- | Retiring a target's swapchain generations
-- ("Hetoimasia.GPU.Vulkan.Native.Generations"), on the graphics owner's
-- thread, before the roots destroy its surface: close it in the model, retire
-- its active generation, destroy every generation whose holds have ended
-- through "Hetoimasia.GPU.Vulkan.Native.Internal.Generations.Disposal", and
-- forget the target only once none remains.
--
-- This module retires the active generation's record, marks the target
-- record 'Closing', and removes it, in
-- "Hetoimasia.GPU.Vulkan.Native.Internal.Generations.State"; it owns no state
-- of its own.
module Hetoimasia.GPU.Vulkan.Native.Internal.Generations.Retirement
  ( retireTargetGenerations
  ) where

import Control.Concurrent.STM (atomically, modifyTVar', readTVar)
import Control.Exception (throwIO)
import Control.Monad (unless, when)
import Data.Foldable (for_)
import qualified Data.Map.Strict as Map
import Data.Maybe (isJust)

import Hetoimasia.Foundation.Time (Instant)
import Hetoimasia.GPU.Model (Outcome (..), closeTarget, retireGeneration)
import Hetoimasia.GPU.Model.Identity (TargetId)
import Hetoimasia.GPU.Vulkan.Native.Internal.Generations.Disposal (disposeEligible)
import Hetoimasia.GPU.Vulkan.Native.Internal.Generations.State
  ( GenerationStanding (..)
  , Generations (..)
  , GenerationsRetained (..)
  , NativeGeneration (..)
  , TargetCondition (..)
  , TargetRecord (..)
  , editGeneration
  , endCpuUse
  , lookupGeneration
  )
import Hetoimasia.GPU.Vulkan.Native.Roots (stateRootsModel)

-- | Retire every generation of a target that is being retired: close it in the
-- model, retire its active generation, and destroy every generation whose
-- holds have ended. Raises 'GenerationsRetained' if any remains, and
-- 'Hetoimasia.GPU.Vulkan.Native.Generations.GenerationDestructionFailed'
-- if a destruction raised; either way nothing is claimed about what remains,
-- and the target's surface is retained above it.
retireTargetGenerations ∷ Generations q inst msgr phys dev → Instant → TargetId → IO ()
retireTargetGenerations generations now target = do
  tracked ← atomically $ do
    record ← Map.lookup target <$> readTVar (generationsTargets generations)
    for_ record $ \entry → do
      stateRootsModel roots $ \model → case closeTarget target model of
        Admitted next → ((), next)
        _ → ((), model)
      for_ (recordActive entry) $ \generation → do
        stateRootsModel roots $ \model → case retireGeneration generation model of
          Admitted next → ((), next)
          _ → ((), model)
        editGeneration generations generation (\native → native {genStanding = GenerationRetiredHeld})
        lookupGeneration generations generation >>= \case
          Just native | genUses native == 0 → endCpuUse generations generation
          _ → pure ()
      modifyTVar' (generationsTargets generations) $
        Map.adjust (\held → held {recordActive = Nothing, recordCondition = Closing}) target
    pure (isJust record)
  when tracked $ do
    (_, failure) ← disposeEligible generations now (Just target)
    for_ failure throwIO
    remaining ← atomically $ do
      record ← Map.lookup target <$> readTVar (generationsTargets generations)
      pure (maybe [] (Map.keys . recordGenerations) record)
    unless (null remaining) (throwIO (GenerationsRetained target remaining))
    atomically (modifyTVar' (generationsTargets generations) (Map.delete target))
  where
    roots = generationsRoots generations
