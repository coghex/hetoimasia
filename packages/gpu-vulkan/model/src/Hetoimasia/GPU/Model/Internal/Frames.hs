-- | Frame reservation and image acquisition.
--
-- This module owns how a frame slot and its presentation-pool record are
-- reserved together, what each acquisition outcome leaves owned, and the rule
-- that an image has at most one unpresented owner. Recording into an acquired
-- frame is "Hetoimasia.GPU.Model.Internal.Recording", submitting it is
-- "Hetoimasia.GPU.Model.Internal.Submission", and presenting or abandoning it is
-- "Hetoimasia.GPU.Model.Internal.Presentation".
module Hetoimasia.GPU.Model.Internal.Frames
  ( AcquireOutcome (..)
  , AcquireAnswer (..)
  , reserveFrame
  , acquireImage
  ) where

import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Hetoimasia.GPU.Model.Internal.Accounting
  ( chargeObjects
  , editFrame
  , editHolds
  , editTarget
  , liveFrames
  , releaseObjects
  , reservedSubmission
  )
import Hetoimasia.GPU.Model.Internal.Budget
  ( BudgetKind (AggregateFrameSlotBudget, FrameSlotBudget, PresentationPoolBudget)
  , aggregateFrameSlotLimit
  , frameSlotLimit
  , presentationPoolCapacity
  )
import Hetoimasia.GPU.Model.Internal.Hold (retainPresentation)
import Hetoimasia.GPU.Model.Internal.Identity
import Hetoimasia.GPU.Model.Internal.Records
import Hetoimasia.GPU.Model.Internal.Resolve (resolveFrame, resolveTarget, targetIdOf)
import Hetoimasia.GPU.Model.Internal.Scheduling (scheduling)
import Hetoimasia.GPU.Model.Internal.State
import Numeric.Natural (Natural)

-- | Reserve a frame slot and, with it, the presentation-pool record that frame
-- will need if it ever acquires an image. The record is reserved /before/
-- acquisition precisely so that backpressure can never leave an admitted frame
-- without the cleanup capacity it needs to be abandoned safely.
reserveFrame ∷ TargetId → GpuModel → Outcome (GpuModel, FrameSlotId)
reserveFrame identity model =
  scheduling model $
  resolved (running model) $ \() →
    resolved (resolveTarget model identity) $ \(number, target) →
      case targetPhase target of
        TargetAdmitted → admit number target
        _ → Rejected (WrongPhase TargetIdentity)
  where
    budgets = gpuBudgets model
    admit number target
      | fromIntegral (Map.size (targetFrames target)) >= frameSlotLimit budgets =
          Backpressure FrameSlotBudget
      | liveFrames model >= aggregateFrameSlotLimit budgets =
          Backpressure AggregateFrameSlotBudget
      | fromIntegral (Map.size (targetPool target)) >= presentationPoolCapacity budgets =
          Backpressure PresentationPoolBudget
      -- Two objects, not one: the presentation-pool record this frame may need,
      -- and the submission record it may need. Both are reserved before the
      -- native calls whose outcomes they account for, so neither can be refused
      -- after one of those calls has already had an effect.
      | otherwise = case chargeObjects 2 model of
          Left kind → Backpressure kind
          Right charged →
            let slot = freeSlot target
                use = maybe 1 (+ 1) (Map.lookup slot (targetSlotUse target))
                record = gpuNextPresentation charged
                frame =
                  Frame
                    { framePhase = FrameReserved
                    , frameUseNumber = use
                    , frameGeneration = Nothing
                    , frameImage = Nothing
                    , frameSuboptimal = False
                    , framePoolRecord = Just record
                    , frameBatches = Set.empty
                    , frameSubmission = Nothing
                    , frameRenderedEpoch = Nothing
                    , frameSubmissionReserved = True
                    , frameFenceReset = False
                    }
             in Admitted
                  ( editTarget
                      number
                      ( \entry →
                          entry
                            { targetFrames = Map.insert slot frame (targetFrames entry)
                            , targetSlotUse = Map.insert slot use (targetSlotUse entry)
                            , targetPool =
                                Map.insert
                                  record
                                  ( PoolRecord
                                      { poolState = PoolReserved
                                      , poolGeneration = Nothing
                                      , poolImage = Nothing
                                      }
                                  )
                                  (targetPool entry)
                            }
                      )
                      charged
                        { gpuNextPresentation = record + 1
                        }
                  , FrameSlotId (targetIdOf charged number target) slot use
                  )
    freeSlot target = search 0
      where
        search candidate
          | Map.member candidate (targetFrames target) = search (candidate + 1)
          | otherwise = candidate

-- | What the presentation engine answered.
data AcquireOutcome
  = AcquiredImage !Natural
  | AcquiredSuboptimalImage !Natural
    -- ^ A successful acquisition. Its image index is never discarded.
  | AcquireNotReady
    -- ^ Not ready or timed out: nothing was acquired.
  | AcquireOutOfDate
  | AcquireSurfaceLost
  deriving (Eq, Show)

data AcquireAnswer
  = ImageOwned !ImageId !Bool
    -- ^ The image and whether the acquisition was suboptimal.
  | ReservationReturned
    -- ^ Only the reservation was released; no image and no synchronization
    -- obligation was ever created, so its pool record goes straight back.
  | ReplacementRequested
    -- ^ No new acquisition obligation. Older obligations are untouched.
  deriving (Eq, Show)

-- | Attempt the acquisition this frame reserved.
acquireImage ∷ FrameSlotId → AcquireOutcome → GpuModel → Outcome (GpuModel, AcquireAnswer)
acquireImage identity outcome model =
  scheduling model $
  -- Only an acquisition that owns an image is new work. One that owned
  -- nothing returns a reservation that was admitted while the session ran,
  -- and it is recorded even when the call's own failure — a device loss —
  -- ended the session: that is the accounting the call's outcome owes.
  resolved (if owning then running model else Right ()) $ \() →
    resolved (resolveFrame model identity) $ \(number, slot, frame) →
      if framePhase frame /= FrameReserved
        then Rejected (WrongPhase FrameIdentity)
        else case Map.lookup number (gpuTargets model) of
          Nothing → Rejected (UnknownIdentity TargetIdentity)
          Just target → case outcome of
            AcquireNotReady → Admitted (returnReservation number slot frame model, ReservationReturned)
            AcquireOutOfDate → Admitted (requestReplacement number (returnReservation number slot frame model), ReplacementRequested)
            AcquireSurfaceLost → Admitted (requestReplacement number (returnReservation number slot frame model), ReplacementRequested)
            AcquiredImage index → own number slot frame target index False
            AcquiredSuboptimalImage index → own number slot frame target index True
  where
    owning = case outcome of
      AcquiredImage _ → True
      AcquiredSuboptimalImage _ → True
      _ → False
    own number slot frame target index suboptimal =
      case targetActiveGeneration target >>= \generation →
        (,) generation <$> Map.lookup generation (targetGenerations target) of
        Nothing → Rejected (WrongPhase GenerationIdentity)
        Just (generation, record)
          | index >= generationImages record → Rejected (UnknownIdentity ImageIdentity)
          -- One image, one *unpresented* owner. A record that took an image keeps
          -- it until its presentation is enqueued, and that record can outlive
          -- the frame, so the check is against the pool rather than against the
          -- frames. Enqueuing hands the image to the presentation engine, after
          -- which P-2 admits a fresh acquisition of it against a separate free
          -- pool record while the older present fence is still pending; the older
          -- record keeps its own image and its own retirement regardless.
          | imageOwned target generation index → Rejected (AlreadyConsumed ImageIdentity)
          | otherwise → case framePoolRecord frame of
              Nothing → Rejected (WrongPhase PresentationIdentity)
              Just pool →
                Admitted
                  ( editHolds
                      (GenerationKey number generation)
                      (retainPresentation pool)
                      ( editTarget
                          number
                          ( \entry →
                              entry
                                { targetPool =
                                    Map.adjust
                                      ( \poolRecord →
                                        poolRecord
                                          { poolGeneration = Just generation
                                          , poolImage = Just index
                                          }
                                    )
                                      pool
                                      (targetPool entry)
                                , targetSuboptimalSeen = targetSuboptimalSeen entry || suboptimal
                                , targetReplacementRequested =
                                    targetReplacementRequested entry + (if suboptimal then 1 else 0)
                                }
                          )
                          ( editFrame
                              number
                              slot
                              ( \entry →
                                  entry
                                    { framePhase = FrameAcquired
                                    , frameGeneration = Just generation
                                    , frameImage = Just index
                                    , frameSuboptimal = suboptimal
                                    }
                              )
                              model
                          )
                      )
                  , ImageOwned
                      (ImageId (GenerationId (targetIdOf model number target) generation) index)
                      suboptimal
                  )

-- | Whether a live pool record of this target still owns that image of that
-- generation against a frame that has not presented it.
--
-- A reserved record — an acquired frame, a submitted one, one whose submission
-- failed without enqueuing a presentation, and one whose effect is uncertain —
-- owns its image outright, and so does one awaiting the explicit settlement of a
-- frame that was never presented. An enqueued record does not: the image is the
-- presentation engine's now, and P-2 permits reacquiring it against separate
-- acquisition synchronization rather than stalling the host on the older present
-- fence. That record is still tracked, still names its own image, and still owes
-- its own retirement.
imageOwned ∷ Target → Natural → Natural → Bool
imageOwned target generation index =
  or
    [ poolGeneration entry == Just generation && poolImage entry == Just index
    | entry ← Map.elems (targetPool target)
    , poolState entry /= PoolEnqueued
    ]

-- | Release a frame that never created an obligation: its slot, its untouched
-- pool record and its unused submission reservation all go back.
returnReservation ∷ Natural → Natural → Frame → GpuModel → GpuModel
returnReservation number slot frame model =
  releaseObjects (maybe 0 (const 1) (framePoolRecord frame) + reservedSubmission frame) $
    editTarget
      number
      ( \entry →
          entry
            { targetFrames = Map.delete slot (targetFrames entry)
            , targetPool = maybe id Map.delete (framePoolRecord frame) (targetPool entry)
            }
      )
      model

-- | Raise a replacement request on a target. Requests are counted rather than
-- flagged, so a publication can satisfy exactly the request it was begun for.
requestReplacement ∷ Natural → GpuModel → GpuModel
requestReplacement number =
  editTarget number (\entry → entry {targetReplacementRequested = targetReplacementRequested entry + 1})
