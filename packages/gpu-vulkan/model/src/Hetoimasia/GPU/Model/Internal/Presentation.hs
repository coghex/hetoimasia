-- | How a frame leaves: enqueuing its presentation, skipping it unsubmitted, or
-- closing it submitted but unpresented.
--
-- This module owns the hand-over of an image to its presentation-pool record,
-- the opening of the presentation-retirement cycle that record identifies, and
-- the settlement a frame that was never presented awaits. The evidence that
-- ends each of those is "Hetoimasia.GPU.Model.Internal.Completion".
module Hetoimasia.GPU.Model.Internal.Presentation
  ( PresentOutcome (..)
  , PresentAnswer (..)
  , enqueuePresentation
  , skipUnsubmittedFrame
  , closeSubmittedFrame
  ) where

import qualified Data.Map.Strict as Map
import Data.Maybe (isJust)
import qualified Data.Set as Set
import Hetoimasia.GPU.Model.Internal.Accounting (editFrame, editTarget, settleFrames)
import Hetoimasia.GPU.Model.Internal.Identity
import Hetoimasia.GPU.Model.Internal.Records
import Hetoimasia.GPU.Model.Internal.Recording (dropBatch)
import Hetoimasia.GPU.Model.Internal.Resolve (resolveFrame)
import Hetoimasia.GPU.Model.Internal.Scheduling (scheduling, scheduling_)
import Hetoimasia.GPU.Model.Internal.State
import Numeric.Natural (Natural)

-- | What the presentation call did.
data PresentOutcome
  = PresentationEnqueued
  | PresentationEnqueuedSuboptimal
  | PresentationEnqueuedOutOfDate
    -- ^ Enqueued, and the surface needs replacing. The enqueued operations are
    -- preserved rather than treated as an unsuccessful acquisition.
  | PresentationEnqueuedSurfaceLost
  | PresentationFailedWithoutEnqueue
    -- ^ A specified result that enqueued nothing.
  deriving (Eq, Show)

data PresentAnswer
  = PresentationTracked !PresentationId
  | PresentationNotEnqueued
    -- ^ The rendering and the still-owned image stay owned; no presentation
    -- fence may be waited on, because this call enqueued none.
  deriving (Eq, Show)

enqueuePresentation ∷ FrameSlotId → PresentOutcome → GpuModel → Outcome (GpuModel, PresentAnswer)
enqueuePresentation identity outcome model =
  scheduling model $
  resolved (resolveFrame model identity) $ \(number, slot, frame) →
    if framePhase frame /= FrameSubmitted
      then Rejected (WrongPhase FrameIdentity)
      else case framePoolRecord frame of
        Nothing → Rejected (WrongPhase PresentationIdentity)
        Just pool → case outcome of
          PresentationFailedWithoutEnqueue → Admitted (model, PresentationNotEnqueued)
          _ →
            Admitted
              ( -- Enqueuing hands the image to the pool record, which is what
                -- makes the slot reusable. Usually the frame's own submission is
                -- still pending and it stays; but a submission that completed
                -- before this call left nothing else owing, and settling here is
                -- what keeps the slot from being held until the presentation
                -- retires.
                settleFrames [(number, slot)] $
                  editTarget
                    number
                    ( \entry →
                        entry
                          { targetPool = Map.adjust (\record → record {poolState = PoolEnqueued}) pool (targetPool entry)
                          , targetReplacementRequested =
                              targetReplacementRequested entry + (if replacing then 1 else 0)
                          , targetRenderDemand = False
                          , -- The cycle opens here, stamped with the epoch it
                            -- belongs to and with whichever half is already in.
                            targetCycles =
                              Map.insert
                                pool
                                Cycle
                                  { -- A submission that completed before this
                                    -- enqueue brings the epoch it completed in
                                    -- with it, rather than being dated to now.
                                    cycleRendered =
                                      if isJust (pending (frameSubmission frame))
                                        then Nothing
                                        else frameRenderedEpoch frame
                                  , cyclePresented = Nothing
                                  , cycleSubmission = pending (frameSubmission frame)
                                  }
                                (targetCycles entry)
                          }
                    )
                    (editFrame number slot (\entry → entry {framePhase = FramePresentationEnqueued}) model)
              , PresentationTracked (PresentationId (frameTarget identity) pool)
              )
  where
    replacing =
      outcome
        `elem` [PresentationEnqueuedSuboptimal, PresentationEnqueuedOutOfDate, PresentationEnqueuedSurfaceLost]
    -- A submission that has already completed is not a half this cycle is still
    -- waiting for.
    pending = \case
      Just submission | Map.member submission (gpuSubmissions model) → Just submission
      _ → Nothing

-- | Safely abandon an acquired, unsubmitted frame. Its unsubmitted recording is
-- discharged; its image and acquisition synchronization are not. The frame keeps
-- its presentation-pool record until the owner supplies explicit settlement
-- evidence, so a skip can never silently recycle a busy record.
skipUnsubmittedFrame ∷ FrameSlotId → GpuModel → Outcome GpuModel
skipUnsubmittedFrame identity model =
  scheduling_ model $
  resolved (resolveFrame model identity) $ \(number, slot, frame) →
    if framePhase frame /= FrameAcquired
      then Rejected (WrongPhase FrameIdentity)
      else
        let discharged = foldl' discard model (Set.toList (frameBatches frame))
         in Admitted (awaitSettlement number slot (framePoolRecord frame) discharged)
  where
    discard current number = case Map.lookup number (gpuBatches current) of
      Nothing → current
      Just batch → dropBatch number batch current

-- | Close a frame that was submitted but never presented. It keeps its
-- submission obligation and its image and synchronization obligations; it is
-- not a skip, and nothing here pretends the submission did not happen.
closeSubmittedFrame ∷ FrameSlotId → GpuModel → Outcome GpuModel
closeSubmittedFrame identity model =
  scheduling_ model $
  resolved (resolveFrame model identity) $ \(number, slot, frame) →
    if framePhase frame /= FrameSubmitted
      then Rejected (WrongPhase FrameIdentity)
      else Admitted (awaitSettlement number slot (framePoolRecord frame) model)

awaitSettlement ∷ Natural → Natural → Maybe Natural → GpuModel → GpuModel
awaitSettlement number slot pool model =
  editTarget
    number
    ( \entry →
        entry
          { targetPool =
              maybe
                id
                (Map.adjust (\record → record {poolState = PoolAwaitingSettlement}))
                pool
                (targetPool entry)
          }
    )
    (editFrame number slot (\entry → entry {framePhase = FrameRetiring}) model)
