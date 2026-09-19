-- | The model itself: one graphics session's targets, generations, frames,
-- records and accounting, and every transition over them.
--
-- Nothing here calls anything, waits for anything, or knows what a swapchain
-- is made of. It is a value the owning boundary threads: each operation takes
-- the model and answers either a new model, a typed backpressure, or a typed
-- misuse that changed nothing. Time enters only as an 'Instant' the caller read
-- from the foundation's injected clock, and completion enters only as a fact
-- the caller supplies through 'EvidenceSource'. The model proves no native
-- completion and cannot: it has no way to observe one.
module Hetoimasia.GPU.Model.Internal.State
  ( -- * The model
    GpuModel
  , newGpuModel
  , modelSessionIdentity
  , modelDeviceId
  , modelBudgets

    -- * Answers
  , Outcome (..)
  , outcomeModel

    -- * Session state
  , SessionState (..)
  , SessionFailureCause (..)
  , Escalation (..)
  , sessionState
  , escalations
  , escalationsDropped
  , takeEscalations
  , escalateSession

    -- * Targets
  , TargetPhase (..)
  , admitTarget
  , suspendTarget
  , resumeTarget
  , requestRender
  , closeTarget

    -- * Generations
  , GenerationPhase (..)
  , PublicationAnswer (..)
  , beginGeneration
  , publishGeneration
  , failGenerationConstruction
  , retireGeneration
  , endGenerationCpuUse

    -- * Managed resources
  , createResource
  , rebuildResource
  , releaseResource
  , endResourceCpuUse

    -- * Frames
  , FramePhase (..)
  , AcquireOutcome (..)
  , AcquireAnswer (..)
  , SubmitOutcome (..)
  , SubmitAnswer (..)
  , PresentOutcome (..)
  , PresentAnswer (..)
  , reserveFrame
  , acquireImage
  , recordBatch
  , discardBatch
  , resetRecorder
  , resetSubmissionFence
  , submitFrames
  , enqueuePresentation
  , skipUnsubmittedFrame
  , closeSubmittedFrame

    -- * Injected evidence
  , CompletionFact (..)
  , DisposalResult (..)
  , EvidenceSource (..)
  , silentEvidence
  , recordCompletion

    -- * Owner progress
  , TurnReport (..)
  , NextTurn (..)
  , runProgressTurn
  , nextDeadline

    -- * Recovery
  , RecoveryAnswer (..)
  , beginTargetRecovery
  , recordRecoveryFailure
  , recordRecoverySuccess

    -- * Allocation attempts
  , beginAllocation
  , recordAllocationFailure
  , noteOldSwapchainRetired
  , retryAllocation
  , abandonAllocation
  , ReclaimReport (..)
  , reclaimPass

    -- * Observation
  , HoldView (..)
  , holdView
  , disposalEligible
  , FrameView (..)
  , frameView
  , presentationImage
  , TargetView (..)
  , targetView
  , Usage (..)
  , usage
  , pendingObligations
  , liveRecordCount
  ) where

import qualified Data.Map.Strict as Map
import Data.Map.Strict (Map)
import Data.Maybe (mapMaybe)
import qualified Data.Set as Set
import Data.Set (Set)
import Data.Either (isLeft)
import Hetoimasia.Foundation.Time (Instant, TimeOverflow (TimeOverflow), addDuration)
import Hetoimasia.GPU.Model.Internal.Budget
  ( BudgetKind
      ( AggregateFrameSlotBudget
      , ByteBudget
      , FrameSlotBudget
      , GenerationBudget
      , ObjectBudget
      , PresentationPoolBudget
      , TargetRecordBudget
      )
  , Budgets
  , aggregateFrameSlotLimit
  , byteLimit
  , frameSlotLimit
  , generationLimit
  , healthyProgressPeriod
  , recoveryAttemptLimit
  , imageTrackingLimit
  , objectLimit
  , presentationPoolCapacity
  , progressActionLimit
  , reclaimExaminationLimit
  , targetRecordLimit
  )
import Hetoimasia.GPU.Model.Internal.Hold
  ( HoldKind
  , Holds (cpuUseEnded, logicalReleased, presentationObligations, recordedReferences, submittedUses)
  , dischargePresentation
  , dischargeRecorded
  , dischargeSubmitted
  , endCpuUse
  , holdsSettled
  , newHolds
  , outstandingHolds
  , retainSubmitted
  , releaseLogically
  , retainPresentation
  , retainRecorded
  )
import Hetoimasia.GPU.Model.Internal.Identity
import Hetoimasia.GPU.Model.Internal.Recovery
  ( AllocationAttempt
      ( attemptBytes
      , attemptFailed
      , attemptObjects
      , attemptReclaimedSince
      , attemptRetiredOldSwapchain
      , attemptRetrySpent
      )
  , BackoffState (backoffDueAt)
  , DueAt (DueAt, DueImmediately, DueUnschedulable)
  , NextAttempt (AttemptAt, AttemptUnschedulable, AttemptUnscheduled)
  , RecoveryEpisode
      ( episodeAttempts
      , episodeHealthySince
      , episodeNextAttemptAt
      , episodeOutstanding
      , episodeRetirementCycle
      )
  , RecoveryProgress
      ( AttemptAdmitted
      , AttemptBudgetExhausted
      , AttemptDeferredUntil
      , AttemptDelayUnrepresentable
      , AttemptStillOutstanding
      )
  , RetryVerdict (RetryPermitted)
  , attemptRecovery
  , freshBackoff
  , freshEpisode
  , judgeRetry
  , newAllocationAttempt
  , noteRetirementCycle
  , observeHealthyProgress
  , recordAttemptFailure
  , recordAttemptSuccess
  , resetBackoff
  , scheduleNextPoll
  )
import Numeric.Natural (Natural)

-- ---------------------------------------------------------------------------
-- Answers

-- | What every mutating operation answers. The three cases are deliberately
-- distinct: an exhausted budget is not a failure, and misuse is not
-- backpressure the caller may wait out.
data Outcome a
  = Admitted !a
    -- ^ The operation happened.
  | Backpressure !BudgetKind
    -- ^ A validated budget is exhausted. Nothing failed and nothing changed;
    -- the caller may try again once the budget frees.
  | Rejected !Misuse
    -- ^ Typed misuse, detected before any state changed.
  deriving (Eq, Show)

instance Functor Outcome where
  fmap function = \case
    Admitted value → Admitted (function value)
    Backpressure kind → Backpressure kind
    Rejected misuse → Rejected misuse

-- | The model an outcome carries, for callers that discard the result.
outcomeModel ∷ Outcome (GpuModel, a) → Outcome GpuModel
outcomeModel = fmap fst

-- | Lift a resolution failure into an outcome.
resolved ∷ Either Misuse a → (a → Outcome b) → Outcome b
resolved (Left misuse) _ = Rejected misuse
resolved (Right value) continue = continue value

-- ---------------------------------------------------------------------------
-- Session state

data SessionFailureCause
  = DeviceLost
  | ValidationError
  | UnknownSubmissionEffect
  | CleanupFailed
  | RequiredTargetUnrecoverable
  deriving (Eq, Ord, Show)

data SessionState
  = SessionRunning
  | SessionFailed !SessionFailureCause
  deriving (Eq, Show)

-- | Something the model escalated. Optional targets are isolated; required
-- targets and every shared-state cause reach the session.
data Escalation
  = OptionalTargetUnavailable !TargetId
  | RequiredTargetFailedSession !TargetId
  | SessionEscalated !SessionFailureCause
  deriving (Eq, Ord, Show)

-- ---------------------------------------------------------------------------
-- Records

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
  , targetReplacementRequested ∷ !Natural
    -- ^ How many replacement requests this target has raised. Compared against
    -- 'targetReplacementServed' rather than cleared, so a request raised while a
    -- replacement was already constructing is not satisfied by that publication.
  , targetReplacementServed ∷ !Natural
  , targetRenderDemand ∷ !Bool
  , targetSuboptimalSeen ∷ !Bool
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
  , submissionSubjects ∷ !(Set SubjectKey)
  , submissionUncertain ∷ !Bool
  }
  deriving (Eq, Show)

data Resource = Resource
  { resourceHolds ∷ !Holds
  , resourceBytes ∷ !Natural
  , resourceObjects ∷ !Natural
  }
  deriving (Eq, Show)

-- | The internal key of a subject that carries holds.
data SubjectKey
  = GenerationKey !Natural !Natural
  | ResourceKey !Natural !Natural
  deriving (Eq, Ord, Show)

-- ---------------------------------------------------------------------------
-- The model

data GpuModel = GpuModel
  { gpuSession ∷ !SessionIdentity
  , gpuDevice ∷ !DeviceId
  , gpuBudgets ∷ !Budgets
  , gpuTargets ∷ !(Map Natural Target)
  , gpuIncarnations ∷ !(Map Natural Natural)
  , gpuNextTarget ∷ !Natural
  , gpuBatches ∷ !(Map Natural Batch)
  , gpuNextBatch ∷ !Natural
  , gpuSubmissions ∷ !(Map Natural Submission)
  , gpuNextSubmission ∷ !Natural
  , gpuNextPresentation ∷ !Natural
  , gpuResources ∷ !(Map (Natural, Natural) Resource)
  , gpuResourceGenerations ∷ !(Map Natural Natural)
  , gpuNextResource ∷ !Natural
  , gpuAllocations ∷ !(Map Natural AllocationAttempt)
  , gpuNextAllocation ∷ !Natural
  , gpuBytes ∷ !Natural
  , gpuObjects ∷ !Natural
  , gpuDisposalFailures ∷ !(Set SubjectKey)
  , gpuBackoff ∷ !BackoffState
  , gpuCursor ∷ !Natural
  , gpuReclaimCursor ∷ !Natural
    -- ^ Where the next reclamation pass starts reading the subject stream. A
    -- pass examines a bounded window of it, so the cursor is what guarantees a
    -- record beyond one window is reached by a later pass rather than never.
  , gpuEscalations ∷ ![Escalation]
    -- ^ Newest first, and bounded: see 'note'.
  , gpuEscalationsDropped ∷ !Natural
  , gpuState ∷ !SessionState
  }
  deriving (Eq, Show)

-- | A session with its validated budgets, one device, and nothing else.
newGpuModel ∷ SessionIdentity → Budgets → (GpuModel, DeviceId)
newGpuModel session budgets = (model, device)
  where
    device = DeviceId session 1
    model =
      GpuModel
        { gpuSession = session
        , gpuDevice = device
        , gpuBudgets = budgets
        , gpuTargets = Map.empty
        , gpuIncarnations = Map.empty
        , gpuNextTarget = 0
        , gpuBatches = Map.empty
        , gpuNextBatch = 0
        , gpuSubmissions = Map.empty
        , gpuNextSubmission = 0
        , gpuNextPresentation = 0
        , gpuResources = Map.empty
        , gpuResourceGenerations = Map.empty
        , gpuNextResource = 0
        , gpuAllocations = Map.empty
        , gpuNextAllocation = 0
        , gpuBytes = 0
        , gpuObjects = 0
        , gpuDisposalFailures = Set.empty
        , gpuBackoff = freshBackoff
        , gpuCursor = 0
        , gpuReclaimCursor = 0
        , gpuEscalations = []
        , gpuEscalationsDropped = 0
        , gpuState = SessionRunning
        }

modelSessionIdentity ∷ GpuModel → SessionIdentity
modelSessionIdentity = gpuSession

modelDeviceId ∷ GpuModel → DeviceId
modelDeviceId = gpuDevice

modelBudgets ∷ GpuModel → Budgets
modelBudgets = gpuBudgets

sessionState ∷ GpuModel → SessionState
sessionState = gpuState

-- | The escalations the model is still holding, oldest first. They are notices
-- for the owning boundary rather than state the model acts on, so a boundary
-- that reads them without 'takeEscalations' sees the retained window.
escalations ∷ GpuModel → [Escalation]
escalations = reverse . gpuEscalations

-- | How many notices were dropped to keep the retained window finite. A dropped
-- notice is counted rather than forgotten, on the same rule as every other
-- accounting here: nothing vanishes unaccounted.
escalationsDropped ∷ GpuModel → Natural
escalationsDropped = gpuEscalationsDropped

-- | Take the retained notices, leaving none behind. This is the consuming read;
-- a boundary that drains each turn never reaches the window's bound.
takeEscalations ∷ GpuModel → (GpuModel, [Escalation])
takeEscalations model = (model {gpuEscalations = []}, escalations model)

-- | Escalate the session. The first cause is kept: a teardown that then fails
-- cleanup must not overwrite the device loss that started it — and only that
-- first cause is notified, so a session cannot accumulate a notice per later
-- failure of a session that has already ended.
escalateSession ∷ SessionFailureCause → GpuModel → GpuModel
escalateSession cause model = case gpuState model of
  SessionFailed _ → model
  SessionRunning → (note (SessionEscalated cause) model) {gpuState = SessionFailed cause}

-- | Retain one notice, keeping the window finite.
--
-- Deduplication alone is not a bound: a target number is reissued under a fresh
-- incarnation, so a session that admits, loses and readmits an optional target
-- for ever would produce a distinct notice every time. The window therefore
-- holds at most one notice per target record the configuration allows, plus the
-- one a failed session can ever raise; beyond that the oldest is dropped and
-- counted.
note ∷ Escalation → GpuModel → GpuModel
note escalation model
  | escalation `elem` gpuEscalations model = model
  | length retained >= capacity =
      model
        { gpuEscalations = escalation : take (capacity - 1) retained
        , gpuEscalationsDropped = gpuEscalationsDropped model + fromIntegral (length retained - (capacity - 1))
        }
  | otherwise = model {gpuEscalations = escalation : retained}
  where
    retained = gpuEscalations model
    capacity = fromIntegral (targetRecordLimit (gpuBudgets model)) + 1

-- | Schedule an immediate progress opportunity. Every transition that creates a
-- retirement or disposal obligation goes through this, because requirement 7's
-- reset is about new work existing and not about who made it: a target that
-- retires a generation while the session has backed off to its idle interval
-- must not wait that interval out before the owner looks at it.
roused ∷ GpuModel → GpuModel
roused model = model {gpuBackoff = resetBackoff (gpuBackoff model)}

running ∷ GpuModel → Either Misuse ()
running model = case gpuState model of
  SessionRunning → Right ()
  SessionFailed _ → Left SessionAlreadyFailed

-- ---------------------------------------------------------------------------
-- Resolution

resolveTarget ∷ GpuModel → TargetId → Either Misuse (Natural, Target)
resolveTarget model identity
  | targetSession identity /= gpuSession model = Left (ForeignIdentity TargetIdentity)
  | otherwise = case Map.lookup number (gpuIncarnations model) of
      Nothing → Left (UnknownIdentity TargetIdentity)
      Just highest
        | incarnation > highest → Left (UnknownIdentity TargetIdentity)
        | otherwise → case Map.lookup number (gpuTargets model) of
            Just target
              | targetIncarnationNumber target == incarnation → Right (number, target)
            _ → Left (StaleIdentity TargetIdentity)
  where
    number = targetNumber identity
    incarnation = targetIncarnation identity

-- | Report a compound identity's parent-resolution failure as being about the
-- identity the caller actually supplied. The category is preserved — a foreign
-- parent still means foreign — because it is the category that tells the caller
-- what went wrong; only the kind is corrected, because naming the parent would
-- describe a value the caller never passed.
asKind ∷ IdentityKind → Either Misuse a → Either Misuse a
asKind kind = either (Left . retarget) Right
  where
    retarget = \case
      ForeignIdentity _ → ForeignIdentity kind
      UnknownIdentity _ → UnknownIdentity kind
      StaleIdentity _ → StaleIdentity kind
      AlreadyConsumed _ → AlreadyConsumed kind
      WrongPhase _ → WrongPhase kind
      WrongParent _ → WrongParent kind
      DuplicateSubject _ → DuplicateSubject kind
      other → other

resolveGeneration ∷ GpuModel → GenerationId → Either Misuse (Natural, Natural, Generation)
resolveGeneration model identity = do
  (number, target) ← asKind GenerationIdentity (resolveTarget model (generationTarget identity))
  let generation = generationNumber identity
  case Map.lookup generation (targetGenerations target) of
    Just record → Right (number, generation, record)
    Nothing
      | generation < targetNextGeneration target → Left (StaleIdentity GenerationIdentity)
      | otherwise → Left (UnknownIdentity GenerationIdentity)

resolveFrame ∷ GpuModel → FrameSlotId → Either Misuse (Natural, Natural, Frame)
resolveFrame model identity = do
  (number, target) ← asKind FrameIdentity (resolveTarget model (frameTarget identity))
  let slot = frameSlotNumber identity
      use = frameUse identity
  case Map.lookup slot (targetFrames target) of
    Just frame
      | frameUseNumber frame == use → Right (number, slot, frame)
    _ → case Map.lookup slot (targetSlotUse target) of
      Just highest
        | use <= highest → Left (StaleIdentity FrameIdentity)
      _ → Left (UnknownIdentity FrameIdentity)

resolveBatch ∷ GpuModel → BatchId → Either Misuse (Natural, Batch)
resolveBatch model identity = do
  _ ← asKind BatchIdentity (resolveTarget model (batchTarget identity))
  let number = batchNumber identity
  case Map.lookup number (gpuBatches model) of
    Just record → Right (number, record)
    Nothing
      | number < gpuNextBatch model → Left (AlreadyConsumed BatchIdentity)
      | otherwise → Left (UnknownIdentity BatchIdentity)

resolveSubmission ∷ GpuModel → SubmissionId → Either Misuse (Natural, Submission)
resolveSubmission model identity
  | submissionSession identity /= gpuSession model = Left (ForeignIdentity SubmissionIdentity)
  | otherwise = case Map.lookup number (gpuSubmissions model) of
      Just record → Right (number, record)
      Nothing
        | number < gpuNextSubmission model → Left (AlreadyConsumed SubmissionIdentity)
        | otherwise → Left (UnknownIdentity SubmissionIdentity)
  where
    number = submissionNumber identity

resolvePresentation ∷ GpuModel → PresentationId → Either Misuse (Natural, Natural, PoolRecord)
resolvePresentation model identity = do
  (number, target) ← asKind PresentationIdentity (resolveTarget model (presentationTarget identity))
  let record = presentationNumber identity
  case Map.lookup record (targetPool target) of
    Just entry → Right (number, record, entry)
    Nothing
      | record < gpuNextPresentation model → Left (AlreadyConsumed PresentationIdentity)
      | otherwise → Left (UnknownIdentity PresentationIdentity)

resolveResource ∷ GpuModel → ResourceId → Either Misuse ((Natural, Natural), Resource)
resolveResource model identity
  | resourceSession identity /= gpuSession model = Left (ForeignIdentity ResourceIdentity)
  | otherwise = case Map.lookup number (gpuResourceGenerations model) of
      Nothing
        -- The resource's last generation has been disposed of and its entry
        -- forgotten. The counter still separates a number this session issued
        -- from one it never did.
        | number < gpuNextResource model → Left (StaleIdentity ResourceIdentity)
        | otherwise → Left (UnknownIdentity ResourceIdentity)
      Just current
        | generation > current → Left (UnknownIdentity ResourceIdentity)
        | otherwise → case Map.lookup key (gpuResources model) of
            Just record → Right (key, record)
            Nothing → Left (StaleIdentity ResourceIdentity)
  where
    number = resourceNumber identity
    generation = resourceGeneration identity
    key = (number, generation)

resolveAllocation ∷ GpuModel → AllocationId → Either Misuse (Natural, AllocationAttempt)
resolveAllocation model identity
  | allocationSession identity /= gpuSession model = Left (ForeignIdentity AllocationIdentity)
  | otherwise = case Map.lookup number (gpuAllocations model) of
      Just attempt → Right (number, attempt)
      Nothing
        | number < gpuNextAllocation model → Left (AlreadyConsumed AllocationIdentity)
        | otherwise → Left (UnknownIdentity AllocationIdentity)
  where
    number = allocationNumber identity

resolveSubject ∷ GpuModel → HoldSubject → Either Misuse SubjectKey
resolveSubject model = \case
  GenerationSubject identity → do
    (target, generation, _) ← resolveGeneration model identity
    Right (GenerationKey target generation)
  ResourceSubject identity → do
    (key, _) ← resolveResource model identity
    Right (uncurry ResourceKey key)

-- ---------------------------------------------------------------------------
-- Naming

targetIdOf ∷ GpuModel → Natural → Target → TargetId
targetIdOf model number target =
  TargetId (gpuSession model) number (targetIncarnationNumber target)

subjectIdentity ∷ GpuModel → SubjectKey → Maybe HoldSubject
subjectIdentity model = \case
  GenerationKey target generation → do
    record ← Map.lookup target (gpuTargets model)
    pure (GenerationSubject (GenerationId (targetIdOf model target record) generation))
  ResourceKey number generation →
    Just (ResourceSubject (ResourceId (gpuSession model) number generation))

-- ---------------------------------------------------------------------------
-- Editing

editTarget ∷ Natural → (Target → Target) → GpuModel → GpuModel
editTarget number change model =
  model {gpuTargets = Map.adjust change number (gpuTargets model)}

editGeneration ∷ Natural → Natural → (Generation → Generation) → GpuModel → GpuModel
editGeneration target generation change =
  editTarget target $ \record →
    record {targetGenerations = Map.adjust change generation (targetGenerations record)}

editFrame ∷ Natural → Natural → (Frame → Frame) → GpuModel → GpuModel
editFrame target slot change =
  editTarget target $ \record →
    record {targetFrames = Map.adjust change slot (targetFrames record)}

editHolds ∷ SubjectKey → (Holds → Holds) → GpuModel → GpuModel
editHolds key change model = case key of
  GenerationKey target generation →
    editGeneration target generation (\record → record {generationHolds = change (generationHolds record)}) model
  ResourceKey number generation →
    model
      { gpuResources =
          Map.adjust
            (\record → record {resourceHolds = change (resourceHolds record)})
            (number, generation)
            (gpuResources model)
      }

holdsOf ∷ GpuModel → SubjectKey → Maybe Holds
holdsOf model = \case
  GenerationKey target generation →
    generationHolds
      <$> (Map.lookup target (gpuTargets model) >>= Map.lookup generation . targetGenerations)
  ResourceKey number generation →
    resourceHolds <$> Map.lookup (number, generation) (gpuResources model)

-- ---------------------------------------------------------------------------
-- Object accounting

chargeObjects ∷ Natural → GpuModel → Either BudgetKind GpuModel
chargeObjects count model
  | gpuObjects model + count > objectLimit (gpuBudgets model) = Left ObjectBudget
  | otherwise = Right model {gpuObjects = gpuObjects model + count}

-- | Subtraction that cannot go below zero, for counters the accounting keeps as
-- 'Natural'.
saturatingMinus ∷ Natural → Natural → Natural
saturatingMinus left right
  | right >= left = 0
  | otherwise = left - right

releaseObjects ∷ Natural → GpuModel → GpuModel
releaseObjects count model
  | count >= gpuObjects model = model {gpuObjects = 0}
  | otherwise = model {gpuObjects = gpuObjects model - count}

releaseBytes ∷ Natural → GpuModel → GpuModel
releaseBytes count model
  | count >= gpuBytes model = model {gpuBytes = 0}
  | otherwise = model {gpuBytes = gpuBytes model - count}

-- ---------------------------------------------------------------------------
-- Targets

-- | Admit a target. Retiring targets still occupy a record, so the limit binds
-- on everything the model still tracks rather than on what is currently
-- rendering. A target number is reused once its record is forgotten, and the
-- reuse carries a fresh incarnation, so an identity for the earlier target is
-- stale rather than a handle on its successor.
admitTarget ∷ TargetClass → GpuModel → Outcome (GpuModel, TargetId)
admitTarget classification model =
  resolved (running model) $ \() →
    if fromIntegral (Map.size (gpuTargets model)) >= targetRecordLimit (gpuBudgets model)
      then Backpressure TargetRecordBudget
      else
        let number = freeTargetNumber model
            incarnation = maybe 1 (+ 1) (Map.lookup number (gpuIncarnations model))
            target =
              Target
                { targetIncarnationNumber = incarnation
                , targetClassOf = classification
                , targetPhase = TargetAdmitted
                , targetGenerations = Map.empty
                , targetNextGeneration = 0
                , targetActiveGeneration = Nothing
                , targetFrames = Map.empty
                , targetSlotUse = Map.empty
                , targetPool = Map.empty
                , targetRecovery = freshEpisode
                , targetReplacementRequested = 0
                , targetReplacementServed = 0
                , targetRenderDemand = False
                , targetSuboptimalSeen = False
                }
         in Admitted
              ( model
                  { gpuTargets = Map.insert number target (gpuTargets model)
                  , gpuIncarnations = Map.insert number incarnation (gpuIncarnations model)
                  , gpuNextTarget = max (gpuNextTarget model) (number + 1)
                  , gpuBackoff = resetBackoff (gpuBackoff model)
                  }
              , TargetId (gpuSession model) number incarnation
              )

freeTargetNumber ∷ GpuModel → Natural
freeTargetNumber model = search 0
  where
    search candidate
      | Map.member candidate (gpuTargets model) = search (candidate + 1)
      | otherwise = candidate

-- | Suspend a target: it keeps every obligation and its retirement demand, and
-- stops contributing a render deadline.
suspendTarget ∷ TargetId → GpuModel → Outcome GpuModel
suspendTarget identity model =
  resolved (running model) $ \() →
    resolved (resolveTarget model identity) $ \(number, target) →
      case targetPhase target of
        TargetAdmitted →
          Admitted (editTarget number (\record → record {targetPhase = TargetSuspended}) model)
        TargetSuspended → Admitted model
        _ → Rejected (WrongPhase TargetIdentity)

resumeTarget ∷ TargetId → GpuModel → Outcome GpuModel
resumeTarget identity model =
  resolved (running model) $ \() →
    resolved (resolveTarget model identity) $ \(number, target) →
      case targetPhase target of
        TargetSuspended →
          Admitted
            ( editTarget number (\record → record {targetPhase = TargetAdmitted}) model
                {gpuBackoff = resetBackoff (gpuBackoff model)}
            )
        TargetAdmitted → Admitted model
        _ → Rejected (WrongPhase TargetIdentity)

-- | New render demand. It schedules an immediate progress opportunity and
-- restarts the idle backoff.
requestRender ∷ TargetId → GpuModel → Outcome GpuModel
requestRender identity model =
  resolved (running model) $ \() →
    resolved (resolveTarget model identity) $ \(number, target) →
      case targetPhase target of
        TargetRetiring → Rejected (WrongPhase TargetIdentity)
        TargetUnavailable → Rejected (WrongPhase TargetIdentity)
        _ →
          Admitted
            ( editTarget number (\record → record {targetRenderDemand = True}) model
                {gpuBackoff = resetBackoff (gpuBackoff model)}
            )

-- | Close a target. Close wins: it drops render demand, and from here no
-- construction may be published back into active rendering.
closeTarget ∷ TargetId → GpuModel → Outcome GpuModel
closeTarget identity model =
  resolved (resolveTarget model identity) $ \(number, _) →
    Admitted
      ( editTarget
          number
          (\record → record {targetPhase = TargetRetiring, targetRenderDemand = False})
          model
          {gpuBackoff = resetBackoff (gpuBackoff model)}
      )

-- ---------------------------------------------------------------------------
-- Generations

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
                    {gpuBackoff = resetBackoff (gpuBackoff charged)}
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
        (roused model)

-- | The construction failed. The candidate is retired; any @oldSwapchain@
-- retirement it performed stays performed.
failGenerationConstruction ∷ GenerationId → GpuModel → Outcome GpuModel
failGenerationConstruction identity model =
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
              (roused model)
          )

-- | Retire an active generation without replacing it.
retireGeneration ∷ GenerationId → GpuModel → Outcome GpuModel
retireGeneration identity model =
  resolved (resolveGeneration model identity) $ \(number, generation, record) →
    case generationPhase record of
      GenerationRetired → Rejected (AlreadyConsumed GenerationIdentity)
      _ →
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
                  (roused model)
              )
          )

-- | Certify that no retained capability can record this generation again. It is
-- a separate fact from retirement: retiring says the owner wants it gone, and
-- this says nothing can still reach it.
endGenerationCpuUse ∷ GenerationId → GpuModel → Outcome GpuModel
endGenerationCpuUse identity model =
  resolved (resolveGeneration model identity) $ \(number, generation, _) →
    Admitted (editGeneration number generation (\entry → entry {generationHolds = endCpuUse (generationHolds entry)}) (roused model))

-- ---------------------------------------------------------------------------
-- Managed resources

-- | Turn a successful allocation attempt into a managed resource generation.
createResource ∷ AllocationId → GpuModel → Outcome (GpuModel, ResourceId)
createResource identity model =
  resolved (running model) $ \() →
    resolved (resolveAllocation model identity) $ \(number, attempt) →
      if attemptFailed attempt
        then Rejected (WrongPhase AllocationIdentity)
        else
          let logical = gpuNextResource model
              record =
                Resource
                  { resourceHolds = newHolds
                  , resourceBytes = attemptBytes attempt
                  , resourceObjects = attemptObjects attempt
                  }
           in Admitted
                ( model
                    { gpuResources = Map.insert (logical, 1) record (gpuResources model)
                    , gpuResourceGenerations = Map.insert logical 1 (gpuResourceGenerations model)
                    , gpuNextResource = logical + 1
                    , gpuAllocations = Map.delete number (gpuAllocations model)
                    }
                , ResourceId (gpuSession model) logical 1
                )

-- | Rebuild a resource under a new generation. The previous generation is
-- released logically and keeps every hold it had, so a batch that recorded it
-- still names exactly the contents it recorded.
rebuildResource ∷ ResourceId → AllocationId → GpuModel → Outcome (GpuModel, ResourceId)
rebuildResource identity allocation model =
  resolved (running model) $ \() →
    resolved (resolveResource model identity) $ \((logical, generation), existing) →
      resolved (resolveAllocation model allocation) $ \(number, attempt) →
        -- Only the resource's current generation may be rebuilt, and the
        -- successor is derived from the resource's own counter rather than from
        -- the identity handed in. Rebuilding through a retained older identity
        -- would otherwise reissue a number that is already live, overwriting one
        -- replacement with another and leaking the accounting of the first.
        if Map.lookup logical (gpuResourceGenerations model) /= Just generation
          then Rejected (StaleIdentity ResourceIdentity)
          else
            if logicalReleased (resourceHolds existing)
              then Rejected (AlreadyConsumed ResourceIdentity)
              else
                if attemptFailed attempt
                  then Rejected (WrongPhase AllocationIdentity)
                  else
                    let next = generation + 1
                        built =
                          Resource
                            { resourceHolds = newHolds
                            , resourceBytes = attemptBytes attempt
                            , resourceObjects = attemptObjects attempt
                            }
                        released = editHolds (ResourceKey logical generation) releaseLogically (roused model)
                     in Admitted
                          ( released
                              { gpuResources = Map.insert (logical, next) built (gpuResources released)
                              , gpuResourceGenerations = Map.insert logical next (gpuResourceGenerations released)
                              , gpuAllocations = Map.delete number (gpuAllocations released)
                              }
                          , ResourceId (gpuSession model) logical next
                          )

releaseResource ∷ ResourceId → GpuModel → Outcome GpuModel
releaseResource identity model =
  resolved (resolveResource model identity) $ \(key, _) →
    Admitted (editHolds (uncurry ResourceKey key) releaseLogically (roused model))

endResourceCpuUse ∷ ResourceId → GpuModel → Outcome GpuModel
endResourceCpuUse identity model =
  resolved (resolveResource model identity) $ \(key, _) →
    Admitted (editHolds (uncurry ResourceKey key) endCpuUse (roused model))

-- ---------------------------------------------------------------------------
-- Frames

-- | Reserve a frame slot and, with it, the presentation-pool record that frame
-- will need if it ever acquires an image. The record is reserved /before/
-- acquisition precisely so that backpressure can never leave an admitted frame
-- without the cleanup capacity it needs to be abandoned safely.
reserveFrame ∷ TargetId → GpuModel → Outcome (GpuModel, FrameSlotId)
reserveFrame identity model =
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
                        , gpuBackoff = resetBackoff (gpuBackoff charged)
                        }
                  , FrameSlotId (targetIdOf charged number target) slot use
                  )
    freeSlot target = search 0
      where
        search candidate
          | Map.member candidate (targetFrames target) = search (candidate + 1)
          | otherwise = candidate

liveFrames ∷ GpuModel → Natural
liveFrames = fromIntegral . sum . map (Map.size . targetFrames) . Map.elems . gpuTargets

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
  resolved (running model) $ \() →
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
    own number slot frame target index suboptimal =
      case targetActiveGeneration target >>= \generation →
        (,) generation <$> Map.lookup generation (targetGenerations target) of
        Nothing → Rejected (WrongPhase GenerationIdentity)
        Just (generation, record)
          | index >= generationImages record → Rejected (UnknownIdentity ImageIdentity)
          -- One image, one owner. A record that took an image keeps it until its
          -- presentation retires or its unpresented frame is settled, and that
          -- record can outlive the frame, so the check is against the pool rather
          -- than against the frames.
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
                      {gpuBackoff = resetBackoff (gpuBackoff model)}
                  , ImageOwned
                      (ImageId (GenerationId (targetIdOf model number target) generation) index)
                      suboptimal
                  )

-- | Whether a live pool record of this target already owns that image of that
-- generation.
imageOwned ∷ Target → Natural → Natural → Bool
imageOwned target generation index =
  or
    [ poolGeneration entry == Just generation && poolImage entry == Just index
    | entry ← Map.elems (targetPool target)
    ]

-- | The object capacity a frame is still holding for a submission record it has
-- not yet used.
reservedSubmission ∷ Frame → Natural
reservedSubmission frame
  | frameSubmissionReserved frame = 1
  | otherwise = 0

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

-- | Record a batch against an acquired frame. The batch retains exactly the
-- resource generations it names and the swapchain generation it renders into.
recordBatch ∷ FrameSlotId → [ResourceId] → GpuModel → Outcome (GpuModel, BatchId)
recordBatch identity references model =
  resolved (running model) $ \() →
    resolved (resolveFrame model identity) $ \(number, slot, frame) →
      if framePhase frame /= FrameAcquired
        then Rejected (WrongPhase FrameIdentity)
        else resolved (traverse (resolveResource model) references) $ \resolvedResources →
          let keys = map (uncurry ResourceKey . fst) resolvedResources
           in if length (Set.toList (Set.fromList keys)) /= length keys
                then Rejected (DuplicateSubject ResourceIdentity)
                else
                  -- A subject whose logical release or ended CPU use has been
                  -- certified may not gain a new recorded reference: the owner
                  -- has already said that nothing can still record it, and a
                  -- batch admitted afterwards would make that certification
                  -- false. Batches already recorded are untouched, and this is
                  -- decided before anything is charged or written.
                  if any (sealed model) (map (uncurry ResourceKey . fst) resolvedResources)
                    then Rejected (WrongPhase ResourceIdentity)
                    else
                      if any (sealed model) [GenerationKey number generation | Just generation ← [frameGeneration frame]]
                        then Rejected (WrongPhase GenerationIdentity)
                        else case chargeObjects 1 model of
                  Left kind → Backpressure kind
                  Right charged →
                    let batch = gpuNextBatch charged
                        generationKeys =
                          [GenerationKey number generation | Just generation ← [frameGeneration frame]]
                        subjects = Set.fromList (keys ++ generationKeys)
                        retained = foldl' (\current key → editHolds key (retainRecorded batch) current) charged (Set.toList subjects)
                     in Admitted
                          ( editFrame
                              number
                              slot
                              (\entry → entry {frameBatches = Set.insert batch (frameBatches entry)})
                              retained
                                { gpuBatches =
                                    Map.insert
                                      batch
                                      Batch
                                        { batchTargetNumber = number
                                        , batchSlot = slot
                                        , batchSubjects = subjects
                                        }
                                      (gpuBatches retained)
                                , gpuNextBatch = batch + 1
                                , gpuBackoff = resetBackoff (gpuBackoff retained)
                                }
                          , BatchId (frameTarget identity) batch
                          )

-- | Whether a subject has been certified as recordable no longer: either the
-- owner released it, or it certified that no retained capability can reach it.
sealed ∷ GpuModel → SubjectKey → Bool
sealed model key = case holdsOf model key of
  Nothing → True
  Just holds → logicalReleased holds || cpuUseEnded holds

-- | Discard one recorded batch. It discharges exactly its own references.
discardBatch ∷ BatchId → GpuModel → Outcome GpuModel
discardBatch identity model =
  resolved (resolveBatch model identity) $ \(number, batch) →
    Admitted (dropBatch number batch model)

dropBatch ∷ Natural → Batch → GpuModel → GpuModel
dropBatch number batch model' =
  let model = roused model'
   in releaseObjects 1 $
    editFrame
      (batchTargetNumber batch)
      (batchSlot batch)
      (\entry → entry {frameBatches = Set.delete number (frameBatches entry)})
      (foldl' (\current key → editHolds key (dischargeRecorded number) current) model (Set.toList (batchSubjects batch)))
        {gpuBatches = Map.delete number (gpuBatches model)}

-- | Reset a frame's recorder: every one of its unsubmitted batches is
-- discarded, and nothing else is.
resetRecorder ∷ FrameSlotId → GpuModel → Outcome GpuModel
resetRecorder identity model =
  resolved (resolveFrame model identity) $ \(_, _, frame) →
    Admitted (foldl' discard model (Set.toList (frameBatches frame)))
  where
    discard current number = case Map.lookup number (gpuBatches current) of
      Nothing → current
      Just batch → dropBatch number batch current

-- | Reset the frame's submission fence. A reset fence with nothing submitted is
-- never pending work: it adds no obligation here and none is counted for it.
resetSubmissionFence ∷ FrameSlotId → GpuModel → Outcome GpuModel
resetSubmissionFence identity model =
  resolved (resolveFrame model identity) $ \(number, slot, frame) →
    if framePhase frame /= FrameAcquired
      then Rejected (WrongPhase FrameIdentity)
      else Admitted (editFrame number slot (\entry → entry {frameFenceReset = True}) model)

-- | What the submission call did.
data SubmitOutcome
  = SubmissionAccepted
  | SubmissionFailedWithoutEffect
    -- ^ A specified result with no effects. Nothing is pending.
  | SubmissionEffectUncertain
    -- ^ Bookkeeping could not be committed after a possibly effective call.
  deriving (Eq, Show)

data SubmitAnswer
  = SubmissionRecorded !SubmissionId
  | AcquisitionRetained
    -- ^ No submission is pending; the acquisition and its recording stay owned.
  | EffectUncertain
    -- ^ The frames entered the uncertain-effect state: parents are retained,
    -- the record can never be discharged, and admission has stopped.
  deriving (Eq, Show)

-- | Submit one or more acquired frames. Frames listed in one call share exactly
-- one submission record; frames submitted by separate calls do not.
submitFrames ∷ [FrameSlotId] → SubmitOutcome → GpuModel → Outcome (GpuModel, SubmitAnswer)
submitFrames identities outcome model
  | null identities = Rejected EmptySubmission
  | otherwise =
      resolved (running model) $ \() →
        resolved (traverse (resolveFrame model) identities) $ \frames →
          let keys = [(number, slot) | (number, slot, _) ← frames]
           in if length (Set.toList (Set.fromList keys)) /= length keys
                then Rejected (DuplicateSubject FrameIdentity)
                else
                  if any (\(_, _, frame) → framePhase frame /= FrameAcquired) frames
                    then Rejected (WrongPhase FrameIdentity)
                    else case outcome of
                      SubmissionFailedWithoutEffect →
                        Admitted (foldl' clearFence model frames, AcquisitionRetained)
                      SubmissionAccepted → accept frames False
                      SubmissionEffectUncertain → accept frames True
  where
    clearFence current (number, slot, _) =
      editFrame number slot (\entry → entry {frameFenceReset = False}) current
    -- No accounting is charged here, and none can be refused here. The object
    -- this record occupies was reserved with the frame, before the native call
    -- whose outcome is now being committed; the other frames of a shared
    -- submission give theirs back, because one record covers them all.
    accept frames uncertain =
      let charged =
            releaseObjects
              (sum [reservedSubmission frame | (_, _, frame) ← frames] `saturatingMinus` 1)
              model
       in accepted charged frames uncertain
    accepted charged frames uncertain =
        let submission = gpuNextSubmission charged
            batches = concat [Set.toList (frameBatches frame) | (_, _, frame) ← frames]
            referenced batch = maybe Set.empty batchSubjects (Map.lookup batch (gpuBatches charged))
            -- Every frame's own swapchain generation is a subject of the
            -- submission whether or not a batch named it: the submitted work
            -- renders into that generation's image, so its completion is owed
            -- even for a submission that recorded nothing.
            rendered =
              Set.fromList
                [ GenerationKey number generation
                | (number, _, frame) ← frames
                , Just generation ← [frameGeneration frame]
                ]
            subjects = Set.unions (rendered : map referenced batches)
            promoted =
              foldl' (\current key → editHolds key (retainSubmitted submission) current) charged (Set.toList subjects)
            dischargedRefs =
              foldl'
                ( \current batch →
                    foldl' (\inner key → editHolds key (dischargeRecorded batch) inner) current (Set.toList (referenced batch))
                )
                promoted
                batches
            withoutBatches =
              (releaseObjects (fromIntegral (length batches)) dischargedRefs)
                {gpuBatches = foldl' (flip Map.delete) (gpuBatches dischargedRefs) batches}
            phase = if uncertain then FrameUncertainEffect else FrameSubmitted
            advanced =
              foldl'
                ( \current (number, slot, _) →
                    editFrame
                      number
                      slot
                      ( \entry →
                          entry
                            { framePhase = phase
                            , frameSubmission = Just submission
                            , frameSubmissionReserved = False
                            , frameBatches = Set.empty
                            , frameFenceReset = False
                            }
                      )
                      current
                )
                withoutBatches
                frames
            recorded =
              advanced
                { gpuSubmissions =
                    Map.insert
                      submission
                      Submission
                        { submissionFrames = [(number, slot) | (number, slot, _) ← frames]
                        , submissionSubjects = subjects
                        , submissionUncertain = uncertain
                        }
                      (gpuSubmissions advanced)
                , gpuNextSubmission = submission + 1
                , gpuBackoff = resetBackoff (gpuBackoff advanced)
                }
         in if uncertain
              then Admitted (escalateSession UnknownSubmissionEffect recorded, EffectUncertain)
              else Admitted (recorded, SubmissionRecorded (SubmissionId (gpuSession recorded) submission))

-- | Raise a replacement request on a target. Requests are counted rather than
-- flagged, so a publication can satisfy exactly the request it was begun for.
requestReplacement ∷ Natural → GpuModel → GpuModel
requestReplacement number =
  editTarget number (\entry → entry {targetReplacementRequested = targetReplacementRequested entry + 1})

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
                          }
                    )
                    (editFrame number slot (\entry → entry {framePhase = FramePresentationEnqueued}) model)
                      {gpuBackoff = resetBackoff (gpuBackoff model)}
              , PresentationTracked (PresentationId (frameTarget identity) pool)
              )
  where
    replacing =
      outcome
        `elem` [PresentationEnqueuedSuboptimal, PresentationEnqueuedOutOfDate, PresentationEnqueuedSurfaceLost]

-- | Safely abandon an acquired, unsubmitted frame. Its unsubmitted recording is
-- discharged; its image and acquisition synchronization are not. The frame keeps
-- its presentation-pool record until the owner supplies explicit settlement
-- evidence, so a skip can never silently recycle a busy record.
skipUnsubmittedFrame ∷ FrameSlotId → GpuModel → Outcome GpuModel
skipUnsubmittedFrame identity model =
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
    {gpuBackoff = resetBackoff (gpuBackoff model)}

-- ---------------------------------------------------------------------------
-- Injected evidence

-- | A fact the owning boundary observed. The model never makes one, and none of
-- them names a native mechanism: what proved the fact is the boundary's
-- business.
data CompletionFact
  = SubmissionCompleted !SubmissionId
  | PresentationRetired !PresentationId
  | UnpresentedFrameSettled !FrameSlotId
    -- ^ An acquired frame that was never presented has had its image and its
    -- synchronization obligations settled.
  deriving (Eq, Show)

data DisposalResult
  = DisposalCompleted
  | DisposalRefused
    -- ^ The boundary declined to dispose of the subject now. Nothing changes.
  | DisposalFailed
    -- ^ The disposal was attempted and failed. Ownership and accounting are
    -- retained and the session escalates; a cleanup failure is never permission
    -- to proceed as though rollback succeeded.
  deriving (Eq, Show)

-- | The interface the owner injects. The model asks; it never assumes.
data EvidenceSource = EvidenceSource
  { submissionEvidence ∷ SubmissionId → Bool
  , presentationEvidence ∷ PresentationId → Bool
  , unpresentedFrameEvidence ∷ FrameSlotId → Bool
  , disposalEvidence ∷ HoldSubject → DisposalResult
  }

-- | An interface that proves nothing and disposes of nothing. A model driven by
-- it can never complete anything, which is exactly the condition storage bounds
-- have to survive.
silentEvidence ∷ EvidenceSource
silentEvidence =
  EvidenceSource
    { submissionEvidence = const False
    , presentationEvidence = const False
    , unpresentedFrameEvidence = const False
    , disposalEvidence = const DisposalRefused
    }

-- | Apply one fact. The instant is the caller's reading of the injected clock;
-- it is used only to date the healthy-progress evidence a recovery reset needs.
recordCompletion ∷ Instant → CompletionFact → GpuModel → Outcome GpuModel
recordCompletion now fact model = case fact of
  SubmissionCompleted identity →
    resolved (resolveSubmission model identity) $ \(number, submission) →
      if submissionUncertain submission
        then Rejected (WrongPhase SubmissionIdentity)
        else Admitted (applySubmission number submission model)
  PresentationRetired identity →
    resolved (resolvePresentation model identity) $ \(number, record, entry) →
      if poolState entry /= PoolEnqueued
        then Rejected (WrongPhase PresentationIdentity)
        else Admitted (applyPresentation now number record entry model)
  UnpresentedFrameSettled identity →
    resolved (resolveFrame model identity) $ \(number, slot, frame) →
      if framePhase frame /= FrameRetiring
        then Rejected (WrongPhase FrameIdentity)
        else case framePoolRecord frame of
          Nothing → Rejected (AlreadyConsumed PresentationIdentity)
          Just pool → Admitted (applySettlement number slot pool frame model)

applySubmission ∷ Natural → Submission → GpuModel → GpuModel
applySubmission number submission model =
  settleFrames (submissionFrames submission) $
    releaseObjects
      1
      ( foldl'
          (\current key → editHolds key (dischargeSubmitted number) current)
          model
          (Set.toList (submissionSubjects submission))
      )
        { gpuSubmissions = Map.delete number (gpuSubmissions model)
        , gpuBackoff = resetBackoff (gpuBackoff model)
        }

applyPresentation ∷ Instant → Natural → Natural → PoolRecord → GpuModel → GpuModel
applyPresentation now number record entry model =
  settleFrames [(number, slot) | slot ← slotsUsing number record model] $
    editTarget
      number
      ( \target →
          target
            { targetPool = Map.delete record (targetPool target)
            , targetRecovery = noteRetirementCycle now (targetRecovery target)
            }
      )
      (releaseObjects 1 (discharge model))
        {gpuBackoff = resetBackoff (gpuBackoff model)}
  where
    discharge current = case poolGeneration entry of
      Nothing → current
      Just generation → editHolds (GenerationKey number generation) (dischargePresentation record) current

applySettlement ∷ Natural → Natural → Natural → Frame → GpuModel → GpuModel
applySettlement number slot pool frame model =
  settleFrames [(number, slot)] $
    editFrame number slot (\entry → entry {framePoolRecord = Nothing}) $
      editTarget
        number
        (\target → target {targetPool = Map.delete pool (targetPool target)})
        (releaseObjects 1 (discharge model))
          {gpuBackoff = resetBackoff (gpuBackoff model)}
  where
    discharge current = case frameGeneration frame of
      Nothing → current
      Just generation → editHolds (GenerationKey number generation) (dischargePresentation pool) current

slotsUsing ∷ Natural → Natural → GpuModel → [Natural]
slotsUsing number record model = case Map.lookup number (gpuTargets model) of
  Nothing → []
  Just target → [slot | (slot, frame) ← Map.toList (targetFrames target), framePoolRecord frame == Just record]

-- | Free every named frame whose obligations have all ended.
--
-- A frame slot owns command storage and acquisition synchronization, so it is
-- reusable once its own submission has completed and it holds no unsubmitted
-- recording. Its presentation record is a separate obligation with a separate
-- lifetime: once a presentation is enqueued, that record has taken over the
-- image, belongs to the target's pool and to its generation's holds, and outlives
-- the slot. A frame that was never presented has handed its record to nobody, so
-- it keeps it — and therefore keeps its slot — until the owner supplies explicit
-- settlement evidence.
settleFrames ∷ [(Natural, Natural)] → GpuModel → GpuModel
settleFrames frames model = foldl' settle model frames
  where
    settle current (number, slot) = case Map.lookup number (gpuTargets current) >>= Map.lookup slot . targetFrames of
      Nothing → current
      Just frame
        | frameSettled current frame →
            releaseObjects
              (reservedSubmission frame)
              (editTarget number (\entry → entry {targetFrames = Map.delete slot (targetFrames entry)}) current)
        | otherwise → current

frameSettled ∷ GpuModel → Frame → Bool
frameSettled model frame =
  Set.null (frameBatches frame)
    && submissionGone
    && (framePhase frame == FramePresentationEnqueued || poolGone)
  where
    poolGone = case framePoolRecord frame of
      Nothing → True
      Just record → not (any (Map.member record . targetPool) (Map.elems (gpuTargets model)))
    submissionGone = case frameSubmission frame of
      Nothing → True
      Just number → not (Map.member number (gpuSubmissions model))

-- ---------------------------------------------------------------------------
-- Owner progress

data TurnReport = TurnReport
  { turnActions ∷ !Natural
  , turnFacts ∷ !Natural
  , turnDisposed ∷ ![HoldSubject]
  , turnDisposalFailures ∷ ![HoldSubject]
  , turnServed ∷ ![TargetId]
    -- ^ The targets this turn visited, in the order it visited them. The lead
    -- rotates every turn, so no target can starve behind a busy neighbour.
  , turnNextDeadline ∷ !NextTurn
  }
  deriving (Eq, Show)

-- | One owner turn: at most the configured number of completion or disposal
-- actions, taken round-robin across targets, followed by the absolute deadline
-- of the next one.
runProgressTurn ∷ EvidenceSource → Instant → GpuModel → (GpuModel, TurnReport)
runProgressTurn source now model = (finished, report)
  where
    budget = progressActionLimit (gpuBudgets model)
    order = rotated (gpuCursor model) (Map.keys (gpuTargets model))
    -- Each pass visits every target once, then the session itself, so managed
    -- resources are reclaimed under the same action budget as target work
    -- rather than through a second unbounded sweep.
    visits = map Just order ++ [Nothing]
    (worked, actions, facts, disposed, failures) = passes model 0 0 [] []
    passes current used factCount disposedSoFar failed
      | used >= budget = (current, used, factCount, disposedSoFar, failed)
      | otherwise =
          let (stepped, stepUsed, stepFacts, stepDisposed, stepFailed) =
                foldl' visit (current, used, factCount, disposedSoFar, failed) visits
           in if stepUsed == used
                then (stepped, stepUsed, stepFacts, stepDisposed, stepFailed)
                else passes stepped stepUsed stepFacts stepDisposed stepFailed
    visit accumulated@(current, used, factCount, disposedSoFar, failed) place
      | used >= budget = accumulated
      | otherwise = case nextAction source current place of
          Nothing → accumulated
          Just action → case applyAction source now current action of
            FactApplied next → (next, used + 1, factCount + 1, disposedSoFar, failed)
            SubjectDisposed next subject → (next, used + 1, factCount, subject : disposedSoFar, failed)
            SubjectDisposalFailed next subject → (next, used + 1, factCount, disposedSoFar, subject : failed)
            ActionDeclined → accumulated
    healthy = foldl' (\current number → editTarget number (\entry → entry {targetRecovery = observeHealthyProgress now (targetRecovery entry)}) current) worked order
    retired = foldl' forgetIfRetired healthy order
    -- The turn is the only place an instant reaches the backoff, so it is the
    -- only place the next poll can be anchored to one.
    backoff = scheduleNextPoll (gpuBudgets retired) now (actions > 0) (gpuBackoff retired)
    finished = retired {gpuBackoff = backoff, gpuCursor = gpuCursor retired + 1}
    report =
      TurnReport
        { turnActions = actions
        , turnFacts = facts
        , turnDisposed = reverse disposed
        , turnDisposalFailures = reverse failures
        , turnServed =
            [ targetIdOf model number target
            | number ← order
            , Just target ← [Map.lookup number (gpuTargets model)]
            ]
        , turnNextDeadline = nextDeadline finished
        }

rotated ∷ Natural → [a] → [a]
rotated _ [] = []
rotated cursor entries = drop offset entries ++ take offset entries
  where
    offset = fromIntegral (cursor `mod` fromIntegral (length entries))

data ActionResult
  = FactApplied !GpuModel
  | SubjectDisposed !GpuModel !HoldSubject
  | SubjectDisposalFailed !GpuModel !HoldSubject
  | ActionDeclined

data PendingAction
  = ApplySubmission !SubmissionId
  | ApplyPresentation !PresentationId
  | ApplySettlement !FrameSlotId
  | DisposeSubject !SubjectKey
  deriving (Eq, Show)

-- | The first action this place offers, in a fixed order: completion facts
-- before disposals, so a turn never spends its whole budget disposing while
-- evidence waits. 'Nothing' names the session itself, whose only work is
-- reclaiming managed resources every hold of which has ended.
nextAction ∷ EvidenceSource → GpuModel → Maybe Natural → Maybe PendingAction
nextAction source model place = case place of
  Nothing →
    firstOf
      [ DisposeSubject key
      | key@(ResourceKey _ _) ← eligibleSubjects model
      , offered key
      ]
  Just number → case Map.lookup number (gpuTargets model) of
    Nothing → Nothing
    Just target →
      firstOf
        [ ApplySubmission identity
        | identity ← submissionsOf target
        , submissionEvidence source identity
        ]
        `orElse` firstOf
          [ ApplyPresentation identity
          | identity ← enqueuedOf number target
          , presentationEvidence source identity
          ]
        `orElse` firstOf
          [ ApplySettlement identity
          | identity ← awaitingOf number target
          , unpresentedFrameEvidence source identity
          ]
        `orElse` firstOf
          [ DisposeSubject key
          | key ← disposableOf number target
          , offered key
          ]
  where
    offered key = case subjectIdentity model key of
      Nothing → False
      Just subject → disposalEvidence source subject /= DisposalRefused
    submissionsOf target =
      [ SubmissionId (gpuSession model) submission
      | frame ← Map.elems (targetFrames target)
      , Just submission ← [frameSubmission frame]
      , Map.member submission (gpuSubmissions model)
      , maybe False (not . submissionUncertain) (Map.lookup submission (gpuSubmissions model))
      ]
    enqueuedOf target' target =
      [ PresentationId (targetIdOf model target' target) record
      | (record, entry) ← Map.toList (targetPool target)
      , poolState entry == PoolEnqueued
      ]
    awaitingOf target' target =
      [ FrameSlotId (targetIdOf model target' target) slot (frameUseNumber frame)
      | (slot, frame) ← Map.toList (targetFrames target)
      , framePhase frame == FrameRetiring
      , Just record ← [framePoolRecord frame]
      , maybe False ((== PoolAwaitingSettlement) . poolState) (Map.lookup record (targetPool target))
      ]
    disposableOf target' target =
      [ GenerationKey target' generation
      | (generation, record) ← Map.toList (targetGenerations target)
      , generationPhase record == GenerationRetired
      , holdsSettled (generationHolds record)
      , GenerationKey target' generation `Set.notMember` gpuDisposalFailures model
      ]
    firstOf entries = case entries of
      [] → Nothing
      entry : _ → Just entry
    orElse (Just value) _ = Just value
    orElse Nothing alternative = alternative

applyAction ∷ EvidenceSource → Instant → GpuModel → PendingAction → ActionResult
applyAction source now model = \case
  ApplySubmission identity → case recordCompletion now (SubmissionCompleted identity) model of
    Admitted next → FactApplied next
    _ → ActionDeclined
  ApplyPresentation identity → case recordCompletion now (PresentationRetired identity) model of
    Admitted next → FactApplied next
    _ → ActionDeclined
  ApplySettlement identity → case recordCompletion now (UnpresentedFrameSettled identity) model of
    Admitted next → FactApplied next
    _ → ActionDeclined
  DisposeSubject key → case subjectIdentity model key of
    Nothing → ActionDeclined
    Just subject → case disposalEvidence source subject of
      DisposalRefused → ActionDeclined
      DisposalCompleted → SubjectDisposed (dispose key model) subject
      -- A failed disposal is preserved rather than replayed: the subject keeps
      -- its ownership and its accounting, it is never offered again, and the
      -- session escalates. Not retrying is what makes the failure bounded; it is
      -- also what keeps a turn from spending its whole budget on one broken
      -- disposal.
      DisposalFailed →
        SubjectDisposalFailed (escalateSession CleanupFailed (rememberFailure key model)) subject

-- | Remove a settled subject and give back exactly the accounting it held.
-- Nothing here is reachable for a subject with an outstanding hold: only
-- 'nextAction' and 'reclaimPass' choose subjects, and both filter on
-- 'holdsSettled' first.
dispose ∷ SubjectKey → GpuModel → GpuModel
dispose key model = case key of
  GenerationKey number generation → case Map.lookup number (gpuTargets model) >>= Map.lookup generation . targetGenerations of
    Nothing → model
    Just record →
      editTarget
        number
        (\entry → entry {targetGenerations = Map.delete generation (targetGenerations entry)})
        (releaseObjects (generationReservedObjects record) model)
  ResourceKey logical generation → case Map.lookup (logical, generation) (gpuResources model) of
    Nothing → model
    Just record →
      let remaining = Map.delete (logical, generation) (gpuResources model)
          -- Once no generation of a logical resource is left, its current-
          -- generation entry is history rather than state, and keeping it would
          -- grow a map that nothing accounts for. A retained identity for it is
          -- still classified as stale, by the monotonic resource counter rather
          -- than by remembering the resource.
          generations
            | any ((== logical) . fst) (Map.keys remaining) = gpuResourceGenerations model
            | otherwise = Map.delete logical (gpuResourceGenerations model)
       in releaseBytes
            (resourceBytes record)
            ( releaseObjects
                (resourceObjects record)
                model {gpuResources = remaining, gpuResourceGenerations = generations}
            )

-- | A retiring target whose records have all gone leaves the model, freeing its
-- number for reuse under a fresh incarnation.
--
-- An attempt still in flight is one of those records, even though it is not one
-- this model holds: forgetting the target would leave the outcome with nothing
-- to be reported against, and the boundary settling it would be told its
-- identity is stale rather than being allowed to settle it.
forgetIfRetired ∷ GpuModel → Natural → GpuModel
forgetIfRetired model number = case Map.lookup number (gpuTargets model) of
  Just target
    | targetPhase target `elem` [TargetRetiring, TargetUnavailable]
    , not (episodeOutstanding (targetRecovery target))
    , Map.null (targetFrames target)
    , Map.null (targetGenerations target)
    , Map.null (targetPool target) →
        model {gpuTargets = Map.delete number (gpuTargets model)}
  _ → model

-- | When the next owner turn is due.
data NextTurn
  = NoTurnNeeded
    -- ^ Nothing is pending and nothing is scheduled.
  | TurnNow
    -- ^ An opportunity is owed immediately: something was scheduled since the
    -- last turn, and the transition that scheduled it carried no clock reading
    -- to anchor an instant to.
  | TurnAt !Instant
    -- ^ The absolute instant of the next turn. One in the past means the owner
    -- is overdue, and is reported as it stands.
  | TurnUnschedulable
    -- ^ There is work, and the instant it is due at does not fit the clock's
    -- representation. It is its own answer rather than 'NoTurnNeeded', because
    -- reading an arithmetic failure as an absence would tell the owner that
    -- nothing needs doing while work is outstanding.
  deriving (Eq, Show)

-- | When the next owner turn is due.
--
-- It takes no instant, and that is the point: the answer is a property of the
-- model alone, so reading the same unchanged model twice gives the same answer
-- however much time has passed between the reads. A deadline recomputed from the
-- reading instant would let an unrelated observation push the next poll further
-- away each time it happened.
--
-- A target with render demand that is not suspended asks for an opportunity now.
-- Otherwise it is the earliest of the instants the model is committed to: the
-- poll the last turn anchored, if any obligation is pending — a suspended target
-- keeps its retirement demand here even though it contributes no render deadline
-- — and every absolute recovery deadline. With nothing pending and nothing
-- scheduled there is nothing to wait for.
nextDeadline ∷ GpuModel → NextTurn
nextDeadline model
  | renderDemand = TurnNow
  | immediate = TurnNow
  -- The earliest representable instant wins. An overflow is reported only when
  -- there is no representable instant at all, because a deadline that is both
  -- actionable and sooner is not made unreachable by some other candidate's
  -- arithmetic failing.
  | not (null scheduled) = TurnAt (minimum scheduled)
  | any isLeft results = TurnUnschedulable
  | otherwise = NoTurnNeeded
  where
    renderDemand =
      or
        [ targetRenderDemand target && targetPhase target == TargetAdmitted
        | target ← Map.elems (gpuTargets model)
        ]
    immediate = obligations > 0 && backoffDueAt (gpuBackoff model) == DueImmediately
    scheduled = [instant | Right instant ← results]
    results = poll ++ recoveryDeadlines model
    poll
      | obligations <= 0 = []
      | otherwise = case backoffDueAt (gpuBackoff model) of
          DueImmediately → []
          DueAt at → [Right at]
          DueUnschedulable → [Left TimeOverflow]
    obligations = fromIntegral (Map.size (gpuSubmissions model)) + recordObligations model ∷ Natural

-- | Every absolute instant a target's recovery accounting has committed to: when
-- its next construction attempt may begin, and when a healthy period that has
-- started would complete and reset its episode.
--
-- Without these the owner is never woken for either. A target whose first
-- attempt has just failed and that is otherwise idle has no obligation to poll
-- for, so a schedule built from obligations alone would advertise no deadline at
-- all; and the episode's reset needs a turn to observe it, so it would never
-- happen, leaving a later recovery starting from a budget that should have been
-- returned.
recoveryDeadlines ∷ GpuModel → [Either TimeOverflow Instant]
recoveryDeadlines model =
  concat
    [ retry episode ++ healthy episode
    | target ← Map.elems (gpuTargets model)
    , targetPhase target `notElem` [TargetRetiring, TargetUnavailable]
    , let episode = targetRecovery target
    ]
  where
    retry episode
      | episodeOutstanding episode = []
      | otherwise = case episodeNextAttemptAt episode of
          AttemptUnscheduled → []
          AttemptAt at → [Right at]
          -- A delay that cannot be expressed is work the owner cannot be given
          -- an instant for, which is exactly what 'TurnUnschedulable' says.
          AttemptUnschedulable → [Left TimeOverflow]
    healthy episode
      | episodeOutstanding episode = []
      | not (episodeRetirementCycle episode) = []
      | otherwise = [addDuration since healthyProgressPeriod | Just since ← [episodeHealthySince episode]]


-- | Everything the model is still waiting on: pending submissions, enqueued
-- presentations, records awaiting settlement, and subjects that are settled but
-- not yet disposed of.
pendingObligations ∷ GpuModel → Natural
pendingObligations model =
  fromIntegral (Map.size (gpuSubmissions model))
    + recordObligations model
    + fromIntegral (length (recoveryDeadlines model))

-- | The obligations that are records rather than schedules: pending submissions
-- are counted by the caller, and these are the rest.
recordObligations ∷ GpuModel → Natural
recordObligations model =
  fromIntegral (length [() | target ← targets, entry ← Map.elems (targetPool target), poolState entry /= PoolReserved])
    + fromIntegral (length (retiring model))
    + fromIntegral (length (eligibleSubjects model))
    -- A target that is retiring is work until it is gone, and only a turn takes
    -- it away. Leaving it out would let a scheduler that follows the answer stop
    -- looking while a record it could free still occupies the target budget.
    + fromIntegral (length [() | target ← targets, targetPhase target `elem` [TargetRetiring, TargetUnavailable]])
    -- So is a replacement nobody is building yet.
    + fromIntegral (length [() | target ← targets, replacementOwed target])
  where
    targets = Map.elems (gpuTargets model)
    -- A retired generation that is not yet settled is still work; once it is
    -- settled it is counted by 'eligibleSubjects' instead, so neither state is
    -- counted twice and a subject whose disposal already failed is counted by
    -- neither.
    retiring current =
      [ ()
      | target ← Map.elems (gpuTargets current)
      , record ← Map.elems (targetGenerations target)
      , generationPhase record == GenerationRetired
      , not (holdsSettled (generationHolds record))
      ]

-- | Whether this target is owed a replacement that no construction is already
-- serving.
--
-- A request raised while a construction was in flight is not covered by it —
-- that construction was begun for an earlier request — so the demand stays, and
-- with it the reason for the owner to come back. A suspended target is left out
-- for the same reason its render deadline is: suspension silences rendering,
-- and a rebuild is rendering work.
replacementOwed ∷ Target → Bool
replacementOwed target =
  targetPhase target == TargetAdmitted
    && targetReplacementRequested target > targetReplacementServed target
    && not (any covering (Map.elems (targetGenerations target)))
  where
    covering record =
      generationPhase record == GenerationConstructing
        && generationServes record >= targetReplacementRequested target

-- ---------------------------------------------------------------------------
-- Recovery

data RecoveryAnswer
  = RecoveryAttempt !Natural
  | RecoveryDeferred !Instant
  | RecoveryClosed
    -- ^ Close takes precedence over retry admission.
  | RecoveryUnschedulable
    -- ^ The delay this episode owes does not fit the clock's representation, so
    -- the attempt cannot be admitted without shortening a delay the episode
    -- exists to enforce.
  | RecoveryOutstanding
    -- ^ An attempt is already in flight. It must be settled with
    -- 'recordRecoveryFailure' or 'recordRecoverySuccess' first, so one
    -- construction can never spend two of the episode's three attempts.
  | RecoveryExhausted !Escalation
  deriving (Eq, Show)

-- | Ask to begin this target's next recovery construction attempt.
beginTargetRecovery ∷ Instant → TargetId → GpuModel → Outcome (GpuModel, RecoveryAnswer)
beginTargetRecovery now identity model =
  -- A terminal session begins no new recovery work. Device loss and the other
  -- session causes are not conditions a target can construct its way out of.
  resolved (running model) $ \() →
    resolved (resolveTarget model identity) $ \(number, target) →
      case targetPhase target of
        TargetRetiring → Admitted (model, RecoveryClosed)
        TargetUnavailable → Admitted (model, RecoveryClosed)
        _ → case attemptRecovery now (targetRecovery target) of
          (_, AttemptStillOutstanding) → Admitted (model, RecoveryOutstanding)
          (_, AttemptDelayUnrepresentable) → Admitted (model, RecoveryUnschedulable)
          -- Reachable only for a target readmitted since its episode was spent:
          -- the final failure exhausts it where it happens, rather than waiting
          -- for someone to ask for an attempt that does not exist.
          (_, AttemptBudgetExhausted) →
            let (next, escalation) = exhaustTarget number target model
             in Admitted (next, RecoveryExhausted escalation)
          (_, AttemptDeferredUntil at) → Admitted (model, RecoveryDeferred at)
          (episode, AttemptAdmitted attempt) →
            Admitted
              ( editTarget number (\entry → entry {targetRecovery = episode}) model
              , RecoveryAttempt attempt
              )

-- | Record that the attempt just made failed. Nothing about a nested helper, a
-- changed geometry observation or an allocation sub-retry reaches this counter
-- except through 'beginTargetRecovery', so none of them can replenish it.
recordRecoveryFailure ∷ Instant → TargetId → GpuModel → Outcome GpuModel
recordRecoveryFailure now identity model =
  resolved (resolveTarget model identity) $ \(number, target) →
    -- A failure is a report about an attempt this episode admitted. Accepting
    -- one with nothing outstanding would spend an attempt on a construction that
    -- never began, and would install a retry delay out of nowhere.
    if not (episodeOutstanding (targetRecovery target))
      then Rejected (WrongPhase TargetIdentity)
      else
        let recorded =
              editTarget number (\entry → entry {targetRecovery = recordAttemptFailure now (targetRecovery entry)}) model
         in -- The last failure of an episode is where recovery is exhausted.
            -- Leaving that to whoever next asks for an attempt would leave the
            -- target admitted, unescalated and unscheduled — and on an otherwise
            -- idle target nobody ever asks.
            --
            -- Unless close already won. An attempt that was outstanding when the
            -- target closed still has to be settled, but its outcome decides
            -- nothing: a target that is retiring is not one recovery can be
            -- exhausted on, and a session that has already failed has no room
            -- for a target to fail it again.
            if episodeAttempts (targetRecovery target) < recoveryAttemptLimit
              || not (stillRecovering model target)
              then Admitted recorded
              else case Map.lookup number (gpuTargets recorded) of
                Nothing → Admitted recorded
                Just spent → Admitted (fst (exhaustTarget number spent recorded))

-- | Whether a failure reported for this target can still exhaust its recovery.
-- A target that has closed, one already marked unavailable, and any target of a
-- session that has already failed have nothing left for recovery to decide.
stillRecovering ∷ GpuModel → Target → Bool
stillRecovering model target =
  gpuState model == SessionRunning
    && targetPhase target `notElem` [TargetRetiring, TargetUnavailable]

-- | Mark a target whose recovery budget is spent: an optional one becomes
-- unavailable and the session continues; a required one fails the session.
exhaustTarget ∷ Natural → Target → GpuModel → (GpuModel, Escalation)
exhaustTarget number target model' = case targetClassOf target of
  OptionalTarget →
    let escalation = OptionalTargetUnavailable (targetIdOf model number target)
     in ( note
            escalation
            (editTarget number (\entry → entry {targetPhase = TargetUnavailable, targetRenderDemand = False}) model)
        , escalation
        )
  RequiredTarget →
    let escalation = RequiredTargetFailedSession (targetIdOf model number target)
     in ( note
            escalation
            ( escalateSession
                RequiredTargetUnrecoverable
                (editTarget number (\entry → entry {targetPhase = TargetRetiring, targetRenderDemand = False}) model)
            )
        , escalation
        )
  where
    model = roused model'

-- | Record that the attempt just made succeeded. It settles the attempt so the
-- episode can admit another later; it does not give the spent attempt back,
-- which only a completed retirement cycle and a healthy second do.
recordRecoverySuccess ∷ TargetId → GpuModel → Outcome GpuModel
recordRecoverySuccess identity model =
  resolved (resolveTarget model identity) $ \(number, target) →
    if not (episodeOutstanding (targetRecovery target))
      then Rejected (WrongPhase TargetIdentity)
      else Admitted (editTarget number (\entry → entry {targetRecovery = recordAttemptSuccess (targetRecovery entry)}) model)

-- ---------------------------------------------------------------------------
-- Allocation attempts

-- | Reserve accounting for one native allocation attempt. Reserving before the
-- call is what makes the byte and object budgets bounds on what the backend can
-- own rather than a report of what it already owns.
beginAllocation ∷ Natural → Natural → GpuModel → Outcome (GpuModel, AllocationId)
beginAllocation bytes objects model =
  resolved (running model) $ \() →
    -- An attempt that reserves neither bytes nor objects would be a record
    -- costing nothing and therefore bounding nothing, which is the one way
    -- attempts could accumulate without limit.
    if bytes == 0 && objects == 0
      then Rejected EmptyAllocation
      else admit
  where
    admit
      | gpuBytes model + bytes > byteLimit (gpuBudgets model)
      =
          Backpressure ByteBudget
      | otherwise = case chargeObjects objects model of
          Left kind → Backpressure kind
          Right charged →
            let number = gpuNextAllocation charged
             in Admitted
                  ( charged
                      { gpuBytes = gpuBytes charged + bytes
                      , gpuAllocations = Map.insert number (newAllocationAttempt bytes objects) (gpuAllocations charged)
                      , gpuNextAllocation = number + 1
                      }
                  , AllocationId (gpuSession charged) number
                  )

recordAllocationFailure ∷ AllocationId → GpuModel → Outcome GpuModel
recordAllocationFailure identity model =
  resolved (resolveAllocation model identity) $ \(number, attempt) →
    if attemptFailed attempt
      then Rejected (AlreadyConsumed AllocationIdentity)
      else
        Admitted
          model
            { gpuAllocations =
                Map.insert number attempt {attemptFailed = True, attemptReclaimedSince = False} (gpuAllocations model)
            }

-- | Record that this attempt's construction already passed a generation as
-- @oldSwapchain@. That retirement is irreversible, so the attempt may not later
-- replay its creation arguments.
noteOldSwapchainRetired ∷ AllocationId → GenerationId → GpuModel → Outcome GpuModel
noteOldSwapchainRetired identity generation model =
  resolved (resolveAllocation model identity) $ \(number, attempt) →
    resolved (resolveGeneration model generation) $ \(_, _, record) →
      if not (generationOldSwapchain record)
        then Rejected (WrongPhase GenerationIdentity)
        else
          Admitted
            model {gpuAllocations = Map.insert number attempt {attemptRetiredOldSwapchain = True} (gpuAllocations model)}

-- | Whether this attempt may retry, spending its one retry bit if it may.
retryAllocation ∷ AllocationId → GpuModel → Outcome (GpuModel, RetryVerdict)
retryAllocation identity model =
  -- A retry is an admission of new native work, so a terminal session refuses
  -- it. Permitting one would invite a native construction whose successful
  -- result 'createResource' then refuses, leaving the boundary holding something
  -- the model has no record of.
  resolved (running model) $ \() →
    resolved (resolveAllocation model identity) $ \(number, attempt) →
      case judgeRetry attempt of
        RetryPermitted →
          Admitted
            ( model
                { gpuAllocations =
                    Map.insert
                      number
                      attempt {attemptRetrySpent = True, attemptFailed = False, attemptReclaimedSince = False}
                      (gpuAllocations model)
                }
            , RetryPermitted
            )
        verdict → Admitted (model, verdict)

-- | Give up an attempt and release the accounting it reserved.
abandonAllocation ∷ AllocationId → GpuModel → Outcome GpuModel
abandonAllocation identity model =
  resolved (resolveAllocation model identity) $ \(number, attempt) →
    Admitted
      ( releaseBytes
          (attemptBytes attempt)
          (releaseObjects (attemptObjects attempt) model {gpuAllocations = Map.delete number (gpuAllocations model)})
      )

data ReclaimReport = ReclaimReport
  { reclaimExamined ∷ !Natural
  , reclaimDisposed ∷ ![HoldSubject]
  , reclaimFailures ∷ ![HoldSubject]
  }
  deriving (Eq, Show)

-- | One bounded reclamation pass over subjects that are already eligible for
-- disposal. It examines at most the configured number of records, waits for
-- nothing, and counts progress only where a disposal actually completed —
-- finding eligible work, or asking for a disposal that then failed, is not
-- progress and unlocks no retry.
reclaimPass ∷ EvidenceSource → GpuModel → (GpuModel, ReclaimReport)
reclaimPass source model = (advanced, report)
  where
    limit = fromIntegral (reclaimExaminationLimit (gpuBudgets model))
    -- The window is taken from every record the model holds, not from the
    -- eligible ones, because deciding that a record is ineligible is itself an
    -- examination. Filtering first would let a pass read the whole model while
    -- reporting that it read almost nothing.
    examined = take limit (rotated (gpuReclaimCursor model) (allSubjects model))
    candidates = filter (eligible model) examined
    (worked, disposedSubjects, failedSubjects) = foldl' step (model, [], []) candidates
    step (current, disposedSoFar, failed) key = case subjectIdentity current key of
      Nothing → (current, disposedSoFar, failed)
      Just subject → case disposalEvidence source subject of
        DisposalRefused → (current, disposedSoFar, failed)
        DisposalCompleted → (dispose key current, subject : disposedSoFar, failed)
        DisposalFailed → (escalateSession CleanupFailed (rememberFailure key current), disposedSoFar, subject : failed)
    advanced = marked {gpuReclaimCursor = gpuReclaimCursor marked + fromIntegral (length examined)}
    marked
      | null disposedSubjects = worked
      | otherwise = worked {gpuAllocations = Map.map credit (gpuAllocations worked)}
    credit attempt
      | attemptFailed attempt && not (attemptRetrySpent attempt) = attempt {attemptReclaimedSince = True}
      | otherwise = attempt
    report =
      ReclaimReport
        { reclaimExamined = fromIntegral (length examined)
        , reclaimDisposed = reverse disposedSubjects
        , reclaimFailures = reverse failedSubjects
        }

-- | Record that a disposal of this subject failed, so it is never offered for
-- disposal again. The subject and its accounting stay exactly where they are.
rememberFailure ∷ SubjectKey → GpuModel → GpuModel
rememberFailure key model =
  model {gpuDisposalFailures = Set.insert key (gpuDisposalFailures model)}

-- | Every record the model holds, in a stable order. This is what a bounded
-- reclamation pass reads a window of.
allSubjects ∷ GpuModel → [SubjectKey]
allSubjects model =
  [ GenerationKey number generation
  | (number, target) ← Map.toList (gpuTargets model)
  , generation ← Map.keys (targetGenerations target)
  ]
    ++ [ResourceKey logical generation | (logical, generation) ← Map.keys (gpuResources model)]

-- | Whether this record may be disposed of: every hold has ended, a generation
-- has been retired, and no earlier disposal of it failed.
eligible ∷ GpuModel → SubjectKey → Bool
eligible model key
  | key `Set.member` gpuDisposalFailures model = False
  | otherwise = case key of
      GenerationKey number generation →
        case Map.lookup number (gpuTargets model) >>= Map.lookup generation . targetGenerations of
          Nothing → False
          Just record → generationPhase record == GenerationRetired && holdsSettled (generationHolds record)
      ResourceKey logical generation →
        maybe False (holdsSettled . resourceHolds) (Map.lookup (logical, generation) (gpuResources model))

-- | Every subject whose holds have all ended and whose disposal has not already
-- been attempted and failed.
eligibleSubjects ∷ GpuModel → [SubjectKey]
eligibleSubjects model = filter (eligible model) (allSubjects model)

-- ---------------------------------------------------------------------------
-- Observation

data HoldView = HoldView
  { viewOutstanding ∷ ![HoldKind]
  , viewRecorded ∷ ![BatchId]
  , viewSubmitted ∷ ![SubmissionId]
  , viewPresentations ∷ ![PresentationId]
  }
  deriving (Eq, Show)

-- | What one subject still owes, or 'Nothing' when it is not this model's.
holdView ∷ HoldSubject → GpuModel → Maybe HoldView
holdView subject model = do
  key ← either (const Nothing) Just (resolveSubject model subject)
  holds ← holdsOf model key
  let owner = case subject of
        GenerationSubject identity → Just (generationTarget identity)
        ResourceSubject _ → Nothing
  pure
    HoldView
      { viewOutstanding = outstandingHolds holds
      , viewRecorded = mapMaybe (\number → BatchId <$> batchOwner number <*> pure number) (Set.toList (recordedReferences holds))
      , viewSubmitted = [SubmissionId (gpuSession model) number | number ← Set.toList (submittedUses holds)]
      , viewPresentations =
          [PresentationId target number | Just target ← [owner], number ← Set.toList (presentationObligations holds)]
      }
  where
    batchOwner number = do
      batch ← Map.lookup number (gpuBatches model)
      target ← Map.lookup (batchTargetNumber batch) (gpuTargets model)
      pure (targetIdOf model (batchTargetNumber batch) target)

-- | Whether every hold on a subject has ended. This is the /only/ condition
-- under which the model will offer it for disposal.
disposalEligible ∷ HoldSubject → GpuModel → Bool
disposalEligible subject model = case holdView subject model of
  Nothing → False
  Just view → null (viewOutstanding view)

data FrameView = FrameView
  { viewFramePhase ∷ !FramePhase
  , viewFrameImage ∷ !(Maybe ImageId)
  , viewFrameSuboptimal ∷ !Bool
  , viewFrameBatches ∷ !Natural
  , viewFrameSubmission ∷ !(Maybe SubmissionId)
  , viewFramePresentation ∷ !(Maybe PresentationId)
  , viewFrameFenceReset ∷ !Bool
  }
  deriving (Eq, Show)

frameView ∷ FrameSlotId → GpuModel → Maybe FrameView
frameView identity model = case resolveFrame model identity of
  Left _ → Nothing
  Right (number, _, frame) → case Map.lookup number (gpuTargets model) of
    Nothing → Nothing
    Just target →
      Just
        FrameView
          { viewFramePhase = framePhase frame
          , viewFrameImage = do
              generation ← frameGeneration frame
              index ← frameImage frame
              pure (ImageId (GenerationId (targetIdOf model number target) generation) index)
          , viewFrameSuboptimal = frameSuboptimal frame
          , viewFrameBatches = fromIntegral (Set.size (frameBatches frame))
          , viewFrameSubmission = SubmissionId (gpuSession model) <$> frameSubmission frame
          , viewFramePresentation = do
              record ← framePoolRecord frame
              entry ← Map.lookup record (targetPool target)
              if poolState entry == PoolEnqueued
                then Just (PresentationId (targetIdOf model number target) record)
                else Nothing
          , viewFrameFenceReset = frameFenceReset frame
          }

-- | The exact image a live presentation record owns. The record outlives its
-- frame, so this answers after the frame slot has been reused and until the
-- retirement — or the explicit settlement of an unpresented frame — that ends it.
presentationImage ∷ PresentationId → GpuModel → Maybe ImageId
presentationImage identity model = case resolvePresentation model identity of
  Left _ → Nothing
  Right (number, _, entry) → do
    generation ← poolGeneration entry
    index ← poolImage entry
    target ← Map.lookup number (gpuTargets model)
    pure (ImageId (GenerationId (targetIdOf model number target) generation) index)

data TargetView = TargetView
  { viewTargetPhase ∷ !TargetPhase
  , viewTargetClass ∷ !TargetClass
  , viewTargetGenerations ∷ !Natural
  , viewTargetActive ∷ !(Maybe GenerationId)
  , viewTargetFrames ∷ !Natural
  , viewTargetPoolRecords ∷ !Natural
  , viewTargetRenderDemand ∷ !Bool
  , viewTargetRetirementDemand ∷ !Bool
  , viewTargetReplacementRequested ∷ !Bool
  , viewTargetRecoveryAttempts ∷ !Natural
  }
  deriving (Eq, Show)

targetView ∷ TargetId → GpuModel → Maybe TargetView
targetView identity model = case resolveTarget model identity of
  Left _ → Nothing
  Right (_, target) →
    Just
      TargetView
        { viewTargetPhase = targetPhase target
        , viewTargetClass = targetClassOf target
        , viewTargetGenerations = fromIntegral (Map.size (targetGenerations target))
        , viewTargetActive = GenerationId identity <$> targetActiveGeneration target
        , viewTargetFrames = fromIntegral (Map.size (targetFrames target))
        , viewTargetPoolRecords = fromIntegral (Map.size (targetPool target))
        , viewTargetRenderDemand = targetRenderDemand target && targetPhase target == TargetAdmitted
        , viewTargetRetirementDemand = retirementDemand target
        , viewTargetReplacementRequested =
            targetReplacementRequested target > targetReplacementServed target
        , viewTargetRecoveryAttempts = recoveryAttemptsOf target
        }

-- | A target owes retirement while it still holds any record at all, whether or
-- not it is suspended. Suspension silences a render deadline; it never silences
-- this.
retirementDemand ∷ Target → Bool
retirementDemand target =
  not (Map.null (targetFrames target))
    || not (Map.null (targetPool target))
    || any ((== GenerationRetired) . generationPhase) (Map.elems (targetGenerations target))

recoveryAttemptsOf ∷ Target → Natural
recoveryAttemptsOf = episodeAttempts . targetRecovery

data Usage = Usage
  { usageTargets ∷ !Natural
  , usageFrames ∷ !Natural
  , usageBatches ∷ !Natural
  , usageSubmissions ∷ !Natural
  , usageBytes ∷ !Natural
  , usageObjects ∷ !Natural
  , usageAllocations ∷ !Natural
  , usageResources ∷ !Natural
  }
  deriving (Eq, Show)

usage ∷ GpuModel → Usage
usage model =
  Usage
    { usageTargets = fromIntegral (Map.size (gpuTargets model))
    , usageFrames = liveFrames model
    , usageBatches = fromIntegral (Map.size (gpuBatches model))
    , usageSubmissions = fromIntegral (Map.size (gpuSubmissions model))
    , usageBytes = gpuBytes model
    , usageObjects = gpuObjects model
    , usageAllocations = fromIntegral (Map.size (gpuAllocations model))
    , usageResources = fromIntegral (Map.size (gpuResources model))
    }

-- | Every record the model is holding. It is bounded by the configuration alone,
-- which is what keeps storage finite when completions never arrive.
liveRecordCount ∷ GpuModel → Natural
liveRecordCount model =
  usageFrames use
    + usageBatches use
    + usageSubmissions use
    + usageAllocations use
    + usageResources use
    + fromIntegral (sum (map (Map.size . targetGenerations) targets))
    + fromIntegral (sum (map (Map.size . targetPool) targets))
    + usageTargets use
  where
    use = usage model
    targets = Map.elems (gpuTargets model)
