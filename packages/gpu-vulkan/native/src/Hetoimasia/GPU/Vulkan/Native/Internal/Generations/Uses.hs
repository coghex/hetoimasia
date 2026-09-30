-- | What any thread may do with a target's generations
-- ("Hetoimasia.GPU.Vulkan.Native.Generations"), in 'STM': report what a
-- swapchain call answered, withdraw the active generation of a target whose
-- window was hidden, and hold and end a CPU use of the active generation. A
-- held use keeps the generation's ended-CPU-use hold on, so the
-- owner's disposal cannot destroy it; ending the last use of a retired
-- generation ends its CPU use in the model.
--
-- This module notes swapchain results and withdrawals and counts uses in the
-- target and
-- generation records of "Hetoimasia.GPU.Vulkan.Native.Internal.Generations.State".
-- The only state it creates is each 'GenerationUse''s own ended flag, which
-- belongs to the holder of that use from 'useGeneration' until it is ended.
module Hetoimasia.GPU.Vulkan.Native.Internal.Generations.Uses
  ( -- * Reports from swapchain calls
    noteSwapchainResult

    -- * Withdrawing the active generation
  , withdrawGeneration

    -- * CPU use
  , GenerationUse
  , UseRefusal (..)
  , useGeneration
  , endGenerationUse
  ) where

import Control.Concurrent.STM (STM, TVar, modifyTVar', newTVar, readTVar, writeTVar)
import Control.Monad (unless)
import qualified Data.Map.Strict as Map
import Data.Maybe (isJust)

import Hetoimasia.GPU.Model.Identity (GenerationId, TargetId, generationTarget)
import Hetoimasia.GPU.Vulkan.Native.Internal.Generations.State
  ( GenerationStanding (..)
  , Generations (..)
  , NativeGeneration (..)
  , SwapchainResult (..)
  , TargetRecord (..)
  , editGeneration
  , endCpuUse
  , lookupGeneration
  )

-- | Withdraw a target's active generation: the target's window was hidden,
-- or is about to be, since the generation last presented. A compositor need
-- not answer a presentation made for a surface it no longer shows, and under
-- Mesa's legacy FIFO on Wayland the generation's next present would wait for
-- that answer for ever (#357). So it presents no more: the target's next
-- reconciliation suspends it, and replaces the generation at once, handing it
-- over, as soon as the target is eligible. A target with no active generation
-- has nothing to withdraw, and one it no longer tracks is left alone.
--
-- It is the owner's, which learns of the hide from its step's view of the
-- target, before any frame of that step is attempted.
withdrawGeneration ∷ Generations q inst msgr phys dev → TargetId → STM ()
withdrawGeneration generations target =
  modifyTVar'
    (generationsTargets generations)
    (Map.adjust (\record → record {recordWithdrawn = recordWithdrawn record || isJust (recordActive record)}) target)

-- | Report what a swapchain call on a generation answered. Only the target's
-- active generation is replaced for an out-of-date or suboptimal result; one
-- about any other generation answers 'False' and changes nothing.
--
-- A lost surface is the surface's, not the generation's: a presentation made
-- on a generation already retired, or an acquisition from it, reports it as
-- truly as the active generation's would. So 'SwapchainSurfaceLost' is taken
-- from any generation the target still tracks — all of them on the surface it
-- holds — unless the surface is already being recovered, when a late report
-- about the lost one says nothing new and must not reach the replacement.
--
-- It is the owner's: the acquisitions and presentations that produce these
-- results run on the graphics owner's thread. A report asks for a step at
-- once through 'Hetoimasia.GPU.Vulkan.Native.Generations.generationsDeadline',
-- so the owner that made it takes the round that reconciles it rather than
-- going idle. A report from another thread wakes nothing.
noteSwapchainResult ∷ Generations q inst msgr phys dev → GenerationId → SwapchainResult → STM Bool
noteSwapchainResult generations generation result = do
  records ← readTVar (generationsTargets generations)
  case Map.lookup (generationTarget generation) records of
    Just record
      | result == SwapchainSurfaceLost, recordSurfaceLost record → pure (Map.member generation (recordGenerations record))
      | recordActive record == Just generation || (result == SwapchainSurfaceLost && Map.member generation (recordGenerations record)) → do
          writeTVar
            (generationsTargets generations)
            (Map.insert (generationTarget generation) record {recordResult = Just (strongest (recordResult record) result), recordResultUnseen = True} records)
          pure True
    _ → pure False
  where
    strongest (Just SwapchainSurfaceLost) _ = SwapchainSurfaceLost
    strongest _ SwapchainSurfaceLost = SwapchainSurfaceLost
    strongest (Just SwapchainOutOfDate) _ = SwapchainOutOfDate
    strongest _ latest = latest

-- | A held CPU use of one generation: while any is held the generation's
-- ended-CPU-use hold stays on, and it is not destroyed.
data GenerationUse = GenerationUse !GenerationId !(TVar Bool)

data UseRefusal
  = UseUnknownGeneration
  | UseNotActive !GenerationStanding
    -- ^ Only the active generation can be used; a retired one never again.
  deriving (Eq, Show)

-- | Hold a CPU use of the target's active generation.
useGeneration ∷ Generations q inst msgr phys dev → GenerationId → STM (Either UseRefusal GenerationUse)
useGeneration generations generation =
  lookupGeneration generations generation >>= \case
    Nothing → pure (Left UseUnknownGeneration)
    Just native
      | genStanding native /= GenerationPresenting → pure (Left (UseNotActive (genStanding native)))
      | otherwise → do
          editGeneration generations generation (\entry → entry {genUses = genUses entry + 1})
          Right . GenerationUse generation <$> newTVar False

-- | End a held use. Ending it twice ends it once. The last use of a retired
-- generation ends its CPU use in the model, which lets the owner destroy it.
endGenerationUse ∷ Generations q inst msgr phys dev → GenerationUse → STM ()
endGenerationUse generations (GenerationUse generation ended) = do
  already ← readTVar ended
  unless already $ do
    writeTVar ended True
    editGeneration generations generation (\entry → entry {genUses = max 1 (genUses entry) - 1})
    lookupGeneration generations generation >>= \case
      Just native
        | genStanding native == GenerationRetiredHeld && genUses native == 0 → endCpuUse generations generation
      _ → pure ()
