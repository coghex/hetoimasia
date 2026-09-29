-- | Swapchain generation lifecycle: construction, publication, construction
-- failure, retirement, and the end of CPU use.
--
-- This module owns a generation's phase, its reserved image-record accounting,
-- the irreversible @oldSwapchain@ retirement, and which replacement request a
-- publication satisfies. A retired generation is disposed of only through
-- "Hetoimasia.GPU.Model.Internal.Disposal", once the eligibility rule in
-- "Hetoimasia.GPU.Model.Internal.Work" permits it.
module Hetoimasia.GPU.Model.Internal.Generations
  ( PublicationAnswer (..)
  , beginGeneration
  , publishGeneration
  , failGenerationConstruction
  , retireGeneration
  , endGenerationCpuUse
  ) where

import qualified Data.Map.Strict as Map
import Hetoimasia.GPU.Model.Internal.Accounting (chargeObjects, editGeneration, editTarget, releaseObjects)
import Hetoimasia.GPU.Model.Internal.Budget (BudgetKind (GenerationBudget), generationLimit, imageTrackingLimit)
import Hetoimasia.GPU.Model.Internal.Hold (endCpuUse, newHolds, releaseLogically)
import Hetoimasia.GPU.Model.Internal.Identity
import Hetoimasia.GPU.Model.Internal.Records
import Hetoimasia.GPU.Model.Internal.Resolve (resolveGeneration, resolveTarget, targetIdOf)
import Hetoimasia.GPU.Model.Internal.Scheduling (scheduling, scheduling_)
import Hetoimasia.GPU.Model.Internal.State
import Numeric.Natural (Natural)

-- | Begin constructing a generation, optionally replacing one by passing it as
-- @oldSwapchain@. That retirement happens here and is irreversible: if the
-- construction then fails, the old generation stays retired and the target has
-- no active generation until a fresh construction succeeds.
--
-- Object capacity for the generation's image records is reserved now, at the
-- configured tracking limit, so publication never has to fail for want of
-- accounting after the native call already happened.
beginGeneration ∷ TargetId → Maybe GenerationId → GpuModel → Outcome (GpuModel, GenerationId)
beginGeneration identity replacing model =
  scheduling model $
  resolved (running model) $ \() →
    resolved (resolveTarget model identity) $ \(number, target) →
      case targetPhase target of
        TargetAdmitted → begin number target
        TargetSuspended → begin number target
        _ → Rejected (WrongPhase TargetIdentity)
  where
    budgets = gpuBudgets model
    -- The identity of the generation being handed over is checked before the
    -- budget is consulted, so a target that is full of records still answers
    -- misuse for an already-retired one rather than the backpressure that would
    -- have followed it.
    begin number target = case replacing of
      Nothing → bounded target (construct number target model)
      Just old → resolved (resolveGeneration model old) $ \(oldTarget, oldNumber, record) →
        -- Both identities are this session's, so this is not foreignness: it is a
        -- generation offered to a target that does not own it.
        if oldTarget /= number
          then Rejected (WrongParent GenerationIdentity)
          else
            if generationPhase record == GenerationRetired
              then Rejected (AlreadyConsumed GenerationIdentity)
              else
                -- Only the target's current published generation may be handed
                -- over. A candidate that is still constructing has nothing to
                -- retire and is not the target's active generation, so accepting
                -- it would record an irreversible retirement of something that
                -- was never published — and would clear the generation that
                -- actually is active.
                if targetActiveGeneration target /= Just oldNumber
                  then Rejected (WrongPhase GenerationIdentity)
                  else bounded target (replace number oldNumber)
    bounded target continue
      | fromIntegral (Map.size (targetGenerations target)) >= generationLimit budgets =
          Backpressure GenerationBudget
      | otherwise = continue
    -- Handing the old generation over retires it here, before anything is known
    -- about the replacement, and nothing undoes that.
    replace number oldNumber =
      let retired =
            editGeneration
              number
              oldNumber
              ( \entry →
                  entry
                    { generationPhase = GenerationRetired
                    , generationOldSwapchain = True
                    , generationHolds = releaseLogically (generationHolds entry)
                    }
              )
              (editTarget number (\entry → entry {targetActiveGeneration = Nothing}) model)
       in case Map.lookup number (gpuTargets retired) of
            Nothing → Rejected (UnknownIdentity TargetIdentity)
            Just updated → construct number updated retired
    construct number target current =
      case chargeObjects (imageTrackingLimit budgets) current of
        Left kind → Backpressure kind
        Right charged →
          let generation = targetNextGeneration target
              record =
                Generation
                  { generationPhase = GenerationConstructing
                  , generationHolds = newHolds
                  , generationImages = 0
                  , generationReservedObjects = imageTrackingLimit budgets
                  , generationOldSwapchain = False
                  , generationServes = targetReplacementRequested target
                  }
           in Admitted
                ( editTarget
                    number
                    ( \entry →
                        entry
                          { targetGenerations = Map.insert generation record (targetGenerations entry)
                          , targetNextGeneration = generation + 1
                          }
                    )
                    charged
                , GenerationId (targetIdOf charged number target) generation
                )

-- | What a publication attempt answers.
data PublicationAnswer
  = GenerationPublished ![ImageId]
    -- ^ The candidate is active and its image records are tracked.
  | GenerationRefusedImageCount !Natural !Natural
    -- ^ The driver offered this many images against this tracking limit — none,
    -- or more than the limit. The candidate is not published; it is retired
    -- instead, and its accounting stays until it is disposed of.
  | PublicationSuperseded
    -- ^ The target closed while the candidate was being constructed. A close
    -- observed after construction requires owned retirement of the result, not
    -- publication back into active rendering.
  deriving (Eq, Show)

-- | Publish a constructed generation with the image count the presentation
-- engine actually returned.
publishGeneration ∷ GenerationId → Natural → GpuModel → Outcome (GpuModel, PublicationAnswer)
publishGeneration identity images model =
  scheduling model $
  resolved (resolveGeneration model identity) $ \(number, generation, record) →
    if generationPhase record /= GenerationConstructing
      then Rejected (WrongPhase GenerationIdentity)
      else case Map.lookup number (gpuTargets model) of
        Nothing → Rejected (UnknownIdentity TargetIdentity)
        Just target
          -- Close wins, a failed session wins, and so does an unusable image
          -- count. In each case the candidate is retired rather than published,
          -- and it keeps the object accounting it reserved until it is actually
          -- disposed of: retired work never vanishes from the metrics.
          --
          -- A failed session is terminal, so a construction that only finished
          -- after the failure has nothing to be published into. It is answered
          -- here rather than refused at the call because the native construction
          -- already happened: its result has to be owned for retirement.
          | gpuState model /= SessionRunning →
              Admitted (retireCandidate number generation, PublicationSuperseded)
          | targetPhase target `elem` [TargetRetiring, TargetUnavailable] →
              Admitted (retireCandidate number generation, PublicationSuperseded)
          | images == 0 || images > limit →
              Admitted (retireCandidate number generation, GenerationRefusedImageCount images limit)
          | otherwise →
              Admitted
                ( editTarget
                    number
                    ( \entry →
                        entry
                          { targetActiveGeneration = Just generation
                          , targetReplacementServed =
                              max (targetReplacementServed entry) (generationServes record)
                          }
                    )
                    ( editGeneration
                        number
                        generation
                        ( \entry →
                            entry
                              { generationPhase = GenerationActive
                              , generationImages = images
                              , generationReservedObjects = images
                              }
                        )
                        (releaseObjects (limit - images) model)
                    )
                , GenerationPublished [ImageId identity index | index ← [0 .. images - 1]]
                )
  where
    limit = imageTrackingLimit (gpuBudgets model)
    retireCandidate number generation =
      editGeneration
        number
        generation
        ( \entry →
            entry
              { generationPhase = GenerationRetired
              , generationHolds = releaseLogically (generationHolds entry)
              }
        )
        model

-- | The construction failed. The candidate is retired; any @oldSwapchain@
-- retirement it performed stays performed.
failGenerationConstruction ∷ GenerationId → GpuModel → Outcome GpuModel
failGenerationConstruction identity model =
  scheduling_ model $
  resolved (resolveGeneration model identity) $ \(number, generation, record) →
    if generationPhase record /= GenerationConstructing
      then Rejected (WrongPhase GenerationIdentity)
      else
        Admitted
          ( editGeneration
              number
              generation
              ( \entry →
                  entry
                    { generationPhase = GenerationRetired
                    , generationHolds = releaseLogically (generationHolds entry)
                    }
              )
              model
          )

-- | Retire an active generation without replacing it.
retireGeneration ∷ GenerationId → GpuModel → Outcome GpuModel
retireGeneration identity model =
  scheduling_ model $
  resolved (resolveGeneration model identity) $ \(number, generation, record) →
    case generationPhase record of
      GenerationRetired → Rejected (AlreadyConsumed GenerationIdentity)
      -- A candidate is not this operation's to retire. Its native construction
      -- has not reported yet, and retiring it here would let it be disposed of
      -- before that outcome arrives — leaving the result with no ownership
      -- record and its own reporting call with nothing but a stale identity.
      -- 'failGenerationConstruction' and 'publishGeneration' are the two ways a
      -- construction ends.
      GenerationConstructing → Rejected (WrongPhase GenerationIdentity)
      GenerationActive →
        Admitted
          ( editTarget
              number
              ( \entry →
                  entry
                    { targetActiveGeneration =
                        if targetActiveGeneration entry == Just generation
                          then Nothing
                          else targetActiveGeneration entry
                    }
              )
              ( editGeneration
                  number
                  generation
                  ( \entry →
                      entry
                        { generationPhase = GenerationRetired
                        , generationHolds = releaseLogically (generationHolds entry)
                        }
                  )
                  model
              )
          )

-- | Certify that no retained capability can record this generation again. It is
-- a separate fact from retirement: retiring says the owner wants it gone, and
-- this says nothing can still reach it.
endGenerationCpuUse ∷ GenerationId → GpuModel → Outcome GpuModel
endGenerationCpuUse identity model =
  scheduling_ model $
  resolved (resolveGeneration model identity) $ \(number, generation, _) →
    Admitted (editGeneration number generation (\entry → entry {generationHolds = endCpuUse (generationHolds entry)}) model)
