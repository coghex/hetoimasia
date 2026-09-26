-- | Disposal for the swapchain generations
-- ("Hetoimasia.GPU.Vulkan.Native.Generations"): destroying, on the graphics
-- owner's thread, every retired generation whose holds the model reports
-- ended — its views, newest first, and then its swapchain, whose images go with
-- it — and the model's progress turn that records each disposal. A
-- destruction that raised is uncertain: the generation is retained, never
-- offered again, and the session fails with 'CleanupFailed'.
--
-- This module clears destroyed handles, advances generation records to
-- destroyed or uncertain, and removes the ones the model recorded as disposed,
-- in the records of "Hetoimasia.GPU.Vulkan.Native.Internal.Generations.State";
-- it owns no state of its own.
module Hetoimasia.GPU.Vulkan.Native.Internal.Generations.Disposal
  ( disposeEligible
  , progress
  ) where

import Control.Concurrent.STM (STM, atomically, modifyTVar', readTVar)
import Control.Exception
  ( Exception (displayException)
  , ExceptionWithContext (ExceptionWithContext)
  , mask_
  , rethrowIO
  , tryWithContext
  )
import Control.Monad (forM, when)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as Text

import Hetoimasia.Foundation.Time (Instant)
import Hetoimasia.GPU.Model
  ( DisposalResult (..)
  , EvidenceSource (..)
  , SessionFailureCause (CleanupFailed)
  , TurnReport (..)
  , disposalEligible
  , runProgressTurn
  , silentEvidence
  )
import Hetoimasia.GPU.Model.Identity (GenerationId, HoldSubject (..), TargetId)
import Hetoimasia.GPU.Vulkan.Native.Internal.Generations.State
  ( GenerationDestructionFailed (..)
  , GenerationStanding (..)
  , Generations (..)
  , NativeGeneration (..)
  , TargetRecord (..)
  , editGeneration
  , isAsynchronous
  )
import Hetoimasia.GPU.Vulkan.Native.Roots
  ( GenerationOps (..)
  , failRootsSession
  , readRootsDevice
  , rootsCall
  , rootsGenerationOps
  , stateRootsModel
  )

-- | Destroy every retired generation whose holds have all ended — of one
-- target, or of all of them — and record the disposals with the model.
--
-- The native destruction comes first and the model is told only what actually
-- happened: a completed destruction is reported completed, and one that raised
-- is reported failed, which retains the generation's accounting and escalates
-- the session.
disposeEligible
  ∷ Generations q inst msgr phys dev
  → Instant
  → Maybe TargetId
  → IO ([GenerationId], Maybe GenerationDestructionFailed)
disposeEligible generations now only = do
  candidates ← atomically $ do
    records ← readTVar (generationsTargets generations)
    model ← stateRootsModel roots (\model → (model, model))
    pure
      [ (generation, native)
      | (target, record) ← Map.toList records
      , maybe True (== target) only
      , (generation, native) ← Map.toList (recordGenerations record)
      , genStanding native == GenerationRetiredHeld
      , disposalEligible (GenerationSubject generation) model
      ]
  device ← atomically (readRootsDevice roots)
  results ← case device of
    Nothing → pure []
    Just (_, handle) → forM candidates $ \(generation, native) → (,) generation <$> destroyGeneration generations handle generation native
  let failures = [(generation, reason) | (generation, Just reason) ← results]
  when (not (null failures)) $ atomically (failRootsSession roots CleanupFailed)
  destroyed ← atomically (progress generations now (evidenceFrom results))
  pure (destroyed, case failures of
    (generation, reason) : _ → Just (GenerationDestructionFailed generation reason)
    [] → Nothing)
  where
    roots = generationsRoots generations
    evidenceFrom results subject = case subject of
      GenerationSubject generation → case lookup generation results of
        Just Nothing → DisposalCompleted
        Just (Just _) → DisposalFailed
        Nothing → DisposalRefused
      _ → DisposalRefused

-- | Destroy one generation's views, newest first, and then its swapchain.
-- Each destruction and the record of it are one masked step; the first that
-- raises marks the generation uncertain and stops, so every parent of what it
-- may have left is retained. Answers the reason, if one did not complete.
destroyGeneration ∷ Generations q inst msgr phys dev → dev → GenerationId → NativeGeneration → IO (Maybe Text)
destroyGeneration generations device generation native = go (reverse (genViews native))
  where
    roots = generationsRoots generations
    ops = rootsGenerationOps roots
    go = \case
      view : rest →
        step "vkDestroyImageView" (opsDestroyImageView ops device view) (\entry → entry {genViews = filter (/= view) (genViews entry)}) >>= \case
          Nothing → go rest
          failure → pure failure
      [] → case genSwapchain native of
        Nothing → finished
        Just swapchain →
          step "vkDestroySwapchainKHR" (opsDestroySwapchain ops device swapchain) (\entry → entry {genSwapchain = Nothing, genImages = []}) >>= \case
            Nothing → finished
            failure → pure failure
    finished = Nothing <$ atomically (editGeneration generations generation (\entry → entry {genStanding = GenerationDestroyedPending}))
    step name destroy record = mask_ $
      tryWithContext (rootsCall roots name destroy) >>= \case
        Right () → Nothing <$ atomically (editGeneration generations generation record)
        Left failure@(ExceptionWithContext _ exception) → do
          let reason = Text.pack (displayException exception)
          atomically $ do
            editGeneration generations generation (\entry → entry {genStanding = GenerationUncertain reason})
            failRootsSession roots CleanupFailed
          if isAsynchronous exception then rethrowIO failure else pure (Just reason)

-- | One model progress turn with the given disposal evidence, forgetting every
-- generation the model recorded as disposed. A generation destroyed natively
-- whose disposal the model did not take this turn keeps answering completed,
-- and one whose destruction was uncertain answers failed, which the model
-- remembers and never offers again.
progress ∷ Generations q inst msgr phys dev → Instant → (HoldSubject → DisposalResult) → STM [GenerationId]
progress generations now evidence = do
  records ← readTVar (generationsTargets generations)
  let standings =
        Map.fromList
          [ (generation, genStanding native)
          | record ← Map.elems records
          , (generation, native) ← Map.toList (recordGenerations record)
          ]
      answer subject = case subject of
        GenerationSubject generation → case Map.lookup generation standings of
          Just GenerationDestroyedPending → DisposalCompleted
          Just (GenerationUncertain _) → DisposalFailed
          _ → evidence subject
        _ → evidence subject
  report ← stateRootsModel (generationsRoots generations) $ \model →
    let (next, turn) = runProgressTurn silentEvidence {disposalEvidence = answer} now model
     in (turn, next)
  let disposed = [generation | GenerationSubject generation ← turnDisposed report]
  modifyTVar' (generationsTargets generations) $
    Map.map (\record → record {recordGenerations = foldr Map.delete (recordGenerations record) disposed})
  pure disposed
