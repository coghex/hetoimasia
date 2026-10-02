-- | The records one graphics session's model is made of: targets and their
-- generations, frame slots, presentation-pool records and retirement cycles,
-- recorded batches, submissions, managed resources, and the key of a subject
-- that carries holds.
--
-- This module owns their representation and nothing else. The model value that
-- holds them is "Hetoimasia.GPU.Model.Internal.State"; every transition over them lives in
-- the module named for its responsibility, and none of them lives here.
module Hetoimasia.GPU.Model.Internal.Records
  ( -- * Phases
    TargetPhase (..)
  , GenerationPhase (..)
  , FramePhase (..)
  , PoolState (..)

    -- * Records
  , PoolRecord (..)
  , Generation (..)
  , Frame (..)
  , Target (..)
  , Cycle (..)
  , Batch (..)
  , Submission (..)
  , Resource (..)
  , InitializationState (..)
  , SubjectKey (..)
  ) where

import Data.Map.Strict (Map)
import Data.Set (Set)
import Hetoimasia.GPU.Model.Internal.Hold (Holds)
import Hetoimasia.GPU.Model.Internal.Identity (BatchId, TargetClass)
import Hetoimasia.GPU.Model.Internal.Recovery (RecoveryEpisode)
import Numeric.Natural (Natural)

data TargetPhase
  = TargetAdmitted
  | TargetSuspended
    -- ^ Zero-area or occluded: no render deadline, but retirement demand and
    -- every outstanding obligation remain.
  | TargetRetiring
  | TargetUnavailable
    -- ^ An optional target whose recovery was exhausted.
  deriving (Eq, Ord, Show)

data GenerationPhase
  = GenerationConstructing
  | GenerationActive
  | GenerationRetired
  deriving (Eq, Ord, Show)

data FramePhase
  = FrameReserved
    -- ^ A slot and a presentation-pool record are reserved; no image is owned.
  | FrameAcquired
    -- ^ An image is owned and nothing has been submitted.
  | FrameSubmitted
  | FramePresentationEnqueued
  | FrameRetiring
    -- ^ Skipped or closed; it keeps exactly the obligations it had.
  | FrameUncertainEffect
    -- ^ A submission whose effect is unknown. Parents are retained and
    -- admission has stopped.
  deriving (Eq, Ord, Show)

data PoolState
  = PoolReserved
  | PoolEnqueued
    -- ^ A presentation was enqueued; only retirement evidence recycles it.
  | PoolAwaitingSettlement
    -- ^ The frame was skipped or closed without presenting; only explicit
    -- settlement evidence recycles it.
  deriving (Eq, Ord, Show)

data PoolRecord = PoolRecord
  { poolState ∷ !PoolState
  , poolGeneration ∷ !(Maybe Natural)
  , poolImage ∷ !(Maybe Natural)
    -- ^ The exact image this record took ownership of at acquisition. The record
    -- outlives its frame once a presentation is enqueued, so the image cannot be
    -- remembered on the frame: the slot is reusable as soon as its own submission
    -- completes, while this record still owes a retirement.
  }
  deriving (Eq, Show)

data Generation = Generation
  { generationPhase ∷ !GenerationPhase
  , generationHolds ∷ !Holds
  , generationImages ∷ !Natural
  , generationReservedObjects ∷ !Natural
  , generationOldSwapchain ∷ !Bool
  , generationServes ∷ !Natural
    -- ^ The replacement request this construction was begun to serve. Publishing
    -- it satisfies exactly that request; one raised while it was constructing
    -- stays pending.
  }
  deriving (Eq, Show)

data Frame = Frame
  { framePhase ∷ !FramePhase
  , frameUseNumber ∷ !Natural
  , frameGeneration ∷ !(Maybe Natural)
  , frameImage ∷ !(Maybe Natural)
  , frameSuboptimal ∷ !Bool
  , framePoolRecord ∷ !(Maybe Natural)
  , frameBatches ∷ !(Set Natural)
  , frameSubmission ∷ !(Maybe Natural)
  , frameRenderedEpoch ∷ !(Maybe Natural)
    -- ^ The recovery epoch in which this frame's submission completed, when that
    -- happened before its presentation was enqueued. The cycle does not exist
    -- yet at that point, so the epoch is remembered here until it does.
  , frameSubmissionReserved ∷ !Bool
    -- ^ Whether this frame still holds the object capacity its submission record
    -- will need. Reserved with the frame, so committing a submission that the
    -- native call already performed can never be refused for want of accounting.
  , frameFenceReset ∷ !Bool
  }
  deriving (Eq, Show)

data Target = Target
  { targetIncarnationNumber ∷ !Natural
  , targetClassOf ∷ !TargetClass
  , targetPhase ∷ !TargetPhase
  , targetGenerations ∷ !(Map Natural Generation)
  , targetNextGeneration ∷ !Natural
  , targetActiveGeneration ∷ !(Maybe Natural)
  , targetFrames ∷ !(Map Natural Frame)
  , targetSlotUse ∷ !(Map Natural Natural)
  , targetPool ∷ !(Map Natural PoolRecord)
  , targetRecovery ∷ !RecoveryEpisode
  , targetRecoveryEpoch ∷ !Natural
    -- ^ Rises whenever a recovery attempt is admitted, and never falls. It lives
    -- on the target rather than on the episode precisely so that resetting the
    -- attempt budget cannot reissue an epoch: evidence stamped with a spent
    -- epoch must stay distinguishable for as long as it exists.
  , targetCycles ∷ !(Map Natural Cycle)
    -- ^ The presentation-retirement cycles in flight, keyed by the presentation
    -- record that identifies each one.
  , targetReplacementRequested ∷ !Natural
    -- ^ How many replacement requests this target has raised. Compared against
    -- 'targetReplacementServed' rather than cleared, so a request raised while a
    -- replacement was already constructing is not satisfied by that publication.
  , targetReplacementServed ∷ !Natural
  , targetRenderDemand ∷ !Bool
  , targetSuboptimalSeen ∷ !Bool
  }
  deriving (Eq, Show)

-- | One normal presentation-retirement cycle: a frame's rendering completing
-- and its presentation retiring. It is the unit a recovery episode's health
-- credit is made of.
--
-- It is held on the target rather than on the frame because the frame is
-- reusable as soon as its own submission completes, and a cycle can outlive
-- that. The presentation record identifies it, and that record's number is
-- never reissued, so two cycles can never be confused for one.
data Cycle = Cycle
  { cycleRendered ∷ !(Maybe Natural)
    -- ^ The target's recovery epoch when the rendering half arrived, once it
    -- has. Each half carries its own epoch rather than the cycle carrying one,
    -- because a half can arrive before the cycle is even opened — a submission
    -- may complete before its presentation is enqueued — and a single stamp
    -- taken at the opening would date that half to the wrong epoch.
  , cyclePresented ∷ !(Maybe Natural)
    -- ^ The same for the presentation half.
  , cycleSubmission ∷ !(Maybe Natural)
    -- ^ The submission whose completion is still awaited, if any.
  }
  deriving (Eq, Show)

data Batch = Batch
  { batchTargetNumber ∷ !Natural
  , batchSlot ∷ !Natural
  , batchSubjects ∷ !(Set SubjectKey)
  }
  deriving (Eq, Show)

data Submission = Submission
  { submissionFrames ∷ ![(Natural, Natural)]
  , submissionBatches ∷ !(Set BatchId)
    -- ^ The batches it consumed, as their full identities: session, target
    -- incarnation and number.
  , submissionSubjects ∷ !(Set SubjectKey)
  , submissionUncertain ∷ !Bool
  }
  deriving (Eq, Show)

data Resource = Resource
  { resourceHolds ∷ !Holds
  , resourceBytes ∷ !Natural
  , resourceObjects ∷ !Natural
  , resourceInitializationState ∷ !InitializationState
  }
  deriving (Eq, Show)

-- | Whether a resource generation's contents are usable yet. Only an image
-- awaits initialization; it advances only on a confirmed submission of the
-- batch that initializes it, and falls back when that batch is dropped.
data InitializationState
  = NoInitialization
    -- ^ Usable from its creation.
  | AwaitingInitialization
  | InitializingBatch !Natural
    -- ^ The batch, by number, that initializes it, not yet submitted.
  | InitializationSubmitted
  deriving (Eq, Show)

-- | The internal key of a subject that carries holds.
data SubjectKey
  = GenerationKey !Natural !Natural
  | ResourceKey !Natural !Natural
  deriving (Eq, Ord, Show)
