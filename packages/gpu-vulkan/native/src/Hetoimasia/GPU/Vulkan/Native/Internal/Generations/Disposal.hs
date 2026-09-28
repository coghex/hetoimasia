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
--
-- It also makes the generations: 'newGenerations' and its variants register
-- the generations' 'SubjectDisposer' with the roots, so a reclamation pass
-- (VK-14) destroys a retired generation exactly as the owner's step would.
module Hetoimasia.GPU.Vulkan.Native.Internal.Generations.Disposal
  ( newGenerations
  , newGenerationsCapturing
  , newGenerationsHooked
  , disposeEligible
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
import Data.List (transpose)
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
  , modelBudgets
  , runProgressTurn
  , silentEvidence
  )
import Hetoimasia.GPU.Model.Budget (progressActionLimit)
import Hetoimasia.GPU.Model.Identity (GenerationId, HoldSubject (..), TargetId)
import Hetoimasia.GPU.Vulkan.Native.Presentation (CaptureUsage (..))
import Hetoimasia.GPU.Vulkan.Native.Internal.Generations.State
  ( GenerationDestructionFailed (..)
  , GenerationStanding (..)
  , Generations (..)
  , NativeGeneration (..)
  , TargetRecord (..)
  , editGeneration
  , isAsynchronous
  , lookupGeneration
  , makeGenerations
  )
import Hetoimasia.GPU.Vulkan.Native.Roots
  ( GenerationOps (..)
  , Roots
  , SubjectDisposer (..)
  , failRootsSessionBecause
  , registerRootsDisposer
  , readRootsDevice
  , rootsCall
  , rootsGenerationOps
  , stateRootsModel
  )

-- | The generations of one session's targets, over its roots.
newGenerations ∷ Roots q inst msgr phys dev → IO (Generations q inst msgr phys dev)
newGenerations = newGenerationsHooked (\_ → pure ())

-- | 'newGenerations' whose every plan also asks for transfer-source usage
-- where the surface offers it ('CaptureWhenOffered'), so a verification can
-- read its images back. No normal target is built this way.
newGenerationsCapturing ∷ Roots q inst msgr phys dev → IO (Generations q inst msgr phys dev)
newGenerationsCapturing roots = registered =<< makeGenerations (\_ → pure ()) CaptureWhenOffered roots

-- | 'newGenerations' with the examples' seam, which runs right after the model
-- admits each candidate. Nothing in production sets it.
newGenerationsHooked ∷ (GenerationId → IO ()) → Roots q inst msgr phys dev → IO (Generations q inst msgr phys dev)
newGenerationsHooked hook roots = registered =<< makeGenerations hook WithoutCapture roots

registered ∷ Generations q inst msgr phys dev → IO (Generations q inst msgr phys dev)
registered generations = generations <$ atomically (registerRootsDisposer (generationsRoots generations) (disposer generations))

-- | What a reclamation pass disposes of the generations' subjects with: a
-- retired generation the model offers — every hold on it ended — is destroyed
-- as 'disposeEligible' destroys one, child before parent, each destruction
-- recorded in its own masked step. One already destroyed, or still building,
-- is not this pass's to destroy, and neither is another layer's subject.
disposer ∷ Generations q inst msgr phys dev → SubjectDisposer
disposer generations =
  SubjectDisposer
    { disposerDispose = \case
        GenerationSubject generation → do
          found ← atomically ((,) <$> lookupGeneration generations generation <*> readRootsDevice (generationsRoots generations))
          case found of
            (Just native, Just (_, device))
              | genStanding native == GenerationRetiredHeld →
                  Just . maybe DisposalCompleted (const DisposalFailed) <$> destroyGeneration generations device generation native
            _ → pure Nothing
        _ → pure Nothing
    , disposerForget = \subjects → do
        let disposed = [generation | GenerationSubject generation ← subjects]
        when (not (null disposed)) $
          modifyTVar' (generationsTargets generations) $
            Map.map (\record → record {recordGenerations = foldr Map.delete (recordGenerations record) disposed})
    }

-- | Destroy every retired generation whose holds have all ended — of one
-- target, or, in the owner's step, of all of them — and record the disposals
-- with the model.
--
-- The owner's step destroys at most the model's progress-action limit of
-- generations, taken round-robin across the targets — one of each target's in
-- turn — starting one target further along each step, so a target with many
-- retired generations cannot hold every other's back and a small limit still
-- reaches every target. Whatever it did not reach waits for a later step, and
-- the model's own schedule keeps the owner stepping while it waits. A target's
-- own retirement or capacity path destroys all of that target's that it can.
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
    let eligible =
          [ [ (generation, native)
            | (generation, native) ← Map.toList (recordGenerations record)
            , genStanding native == GenerationRetiredHeld
            , disposalEligible (GenerationSubject generation) model
            ]
          | (target, record) ← Map.toList records
          , maybe True (== target) only
          ]
    case only of
      Just _ → pure (concat eligible)
      Nothing → do
        cursor ← readTVar (generationsCursor generations)
        modifyTVar' (generationsCursor generations) (+ 1)
        let offset = if null eligible then 0 else fromIntegral (cursor `mod` fromIntegral (length eligible))
            turns = drop offset eligible <> take offset eligible
        pure (take (fromIntegral (progressActionLimit (modelBudgets model))) (concat (transpose turns)))
  device ← atomically (readRootsDevice roots)
  results ← case device of
    Nothing → pure []
    Just (_, handle) → forM candidates $ \(generation, native) → (,) generation <$> destroyGeneration generations handle generation native
  let failures = [(generation, reason) | (generation, Just reason) ← results]
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
            failRootsSessionBecause roots CleanupFailed (name <> " of " <> Text.pack (show generation) <> " raised: " <> reason)
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
