-- | A pure model of GPU resource retention and frame ownership.
--
-- __What this is.__ One graphics session's targets, swapchain generations,
-- frame slots, recorded batches, submissions, presentations, managed resources
-- and allocation attempts, together with the accounting that decides when any of
-- them may be disposed of. It is a value: every operation takes the model and
-- answers a new one, a typed backpressure, or a typed misuse that changed
-- nothing.
--
-- __What this is not.__ It makes no native call, names no native type, owns no
-- thread and proves no completion. A submitted use ends when, and only when, the
-- owning boundary supplies the fact through 'EvidenceSource'; there is no path
-- by which elapsed time, a returned call, a cancellation or a CPU scope exit
-- becomes completion evidence. Which native mechanism proved a fact is the
-- boundary's business and is deliberately absent from the fact.
--
-- __Holds.__ Five holds are tracked separately on each generation and each
-- managed resource: logical release, ended CPU use, recorded-but-unsubmitted
-- references, submitted uses keyed by their submission record, and presentation
-- obligations keyed by their presentation record. 'disposalEligible' answers
-- only when every one of them has ended, and the model offers nothing else for
-- disposal.
--
-- __Frames.__ A frame passes through reservation, acquisition, submission,
-- presentation enqueue, retirement and reuse, and each phase names the
-- obligations it retains and the exits that are legal from it. A not-ready
-- acquisition releases only its reservation; a suboptimal one keeps its image; a
-- skipped unsubmitted frame and a submitted-but-unpresented close each keep
-- exactly their own obligations until settled; a no-effect submission failure
-- leaves the acquisition owned, while an uncertain-effect outcome enters an
-- explicit state that retains its parents and stops admission.
--
-- __Bounds.__ Every budget is finite and validated before a model exists, and
-- exhaustion is a typed 'Backpressure' answer rather than a failure. It never
-- consumes the cleanup records already reserved for admitted work, and retired
-- work keeps its accounting until it is actually disposed of.
--
-- __Time.__ Instants come from the foundation's injected clock and are passed in;
-- the model reads no clock of its own. The owner's progress turn does bounded
-- work round-robin across targets and answers the absolute deadline of the next
-- one.
--
-- See @docs/gpu_model.md@ for the same contract in prose,
-- "Hetoimasia.GPU.Model.Identity" for the identities, and
-- "Hetoimasia.GPU.Model.Budget" for the configuration.
module Hetoimasia.GPU.Model
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
  , runProgressTurn
  , nextDeadline
  , pendingObligations

    -- * Recovery
  , RecoveryAnswer (..)
  , beginTargetRecovery
  , recordRecoveryFailure
  , recordRecoverySuccess

    -- * Allocation attempts
  , RetryVerdict (..)
  , beginAllocation
  , recordAllocationFailure
  , noteOldSwapchainRetired
  , retryAllocation
  , abandonAllocation
  , ReclaimReport (..)
  , reclaimPass

    -- * Observation
  , HoldKind (..)
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
  , liveRecordCount
  ) where

import Hetoimasia.GPU.Model.Internal.Hold (HoldKind (..))
import Hetoimasia.GPU.Model.Internal.Recovery (RetryVerdict (..))
import Hetoimasia.GPU.Model.Internal.State
