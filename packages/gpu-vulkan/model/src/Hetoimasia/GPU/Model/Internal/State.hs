-- | The model itself: one graphics session's targets, generations, frames,
-- records and accounting, as a single immutable value.
--
-- Nothing in the model calls anything, waits for anything, or knows what a
-- swapchain is made of. It is a value the owning boundary threads: each
-- operation takes the model and answers either a new model, a typed
-- backpressure, or a typed misuse that changed nothing. Time enters only as an
-- 'Hetoimasia.Foundation.Time.Instant' the caller read from the foundation's
-- injected clock, and completion enters only as a fact the caller supplies
-- through the injected evidence interface. The model proves no native
-- completion and cannot: it has no way to observe one.
--
-- This module owns the representation of that value, its construction, the
-- three-way 'Outcome' every mutating operation answers, and the session state
-- that gates admission. The records it holds are "Hetoimasia.GPU.Model.Internal.Records".
-- Transitions live in the modules named for their responsibility, and each
-- applies the one scheduling rule in "Hetoimasia.GPU.Model.Internal.Scheduling".
module Hetoimasia.GPU.Model.Internal.State
  ( -- * The model
    GpuModel (..)
  , newGpuModel
  , modelSessionIdentity
  , modelDeviceId
  , modelBudgets

    -- * Answers
  , Outcome (..)
  , outcomeModel
  , resolved

    -- * Session state
  , SessionState (..)
  , SessionFailureCause (..)
  , Escalation (..)
  , sessionState
  , running
  ) where

import qualified Data.Map.Strict as Map
import Data.Map.Strict (Map)
import qualified Data.Set as Set
import Data.Set (Set)
import Hetoimasia.GPU.Model.Internal.Budget (BudgetKind, Budgets)
import Hetoimasia.GPU.Model.Internal.Identity
import Hetoimasia.GPU.Model.Internal.Records (Batch, FramelessSlot, Resource, Submission, SubjectKey, Target)
import Hetoimasia.GPU.Model.Internal.Recovery (AllocationAttempt, BackoffState, freshBackoff)
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
  | DiagnosticSinkFailed
    -- ^ The diagnostic consumer's sink failed: a separate terminal status that
    -- stops admission like the others and never replaces an earlier cause.
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

sessionState ∷ GpuModel → SessionState
sessionState = gpuState

running ∷ GpuModel → Either Misuse ()
running model = case gpuState model of
  SessionRunning → Right ()
  SessionFailed _ → Left SessionAlreadyFailed

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
  , gpuFramelessSlots ∷ !(Map Natural FramelessSlot)
    -- ^ The frame-less slots in use, each until its batch is dropped or its
    -- submission's completion is recorded (GRS-12). Their number is bounded
    -- by the frame-less batch budget.
  , gpuSubmissions ∷ !(Map Natural Submission)
  , gpuNextSubmission ∷ !Natural
  , gpuNextPresentation ∷ !Natural
  , gpuResources ∷ !(Map (Natural, Natural) Resource)
  , gpuResourceGenerations ∷ !(Map Natural Natural)
  , gpuNextResource ∷ !Natural
  , gpuAllocations ∷ !(Map Natural AllocationAttempt)
  , gpuNextAllocation ∷ !Natural
  , gpuBytes ∷ !Natural
    -- ^ Every accounted byte: resources' own bytes, attempts' reservations,
    -- and the device memory held ('gpuDeviceMemory').
  , gpuDeviceMemory ∷ !Natural
    -- ^ The device memory the allocator holds, as its calls' effects were
    -- settled: each block and dedicated allocation until it is freed.
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
  , gpuDeviceLost ∷ !Bool
    -- ^ Whether the boundary observed the device's loss. It is kept apart from
    -- the session's first cause: a session that another cause failed first
    -- keeps that cause, while its teardown still switches to the device-loss
    -- rules once the loss is observed.
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
        , gpuFramelessSlots = Map.empty
        , gpuSubmissions = Map.empty
        , gpuNextSubmission = 0
        , gpuNextPresentation = 0
        , gpuResources = Map.empty
        , gpuResourceGenerations = Map.empty
        , gpuNextResource = 0
        , gpuAllocations = Map.empty
        , gpuNextAllocation = 0
        , gpuBytes = 0
        , gpuDeviceMemory = 0
        , gpuObjects = 0
        , gpuDisposalFailures = Set.empty
        , gpuBackoff = freshBackoff
        , gpuCursor = 0
        , gpuReclaimCursor = 0
        , gpuEscalations = []
        , gpuEscalationsDropped = 0
        , gpuState = SessionRunning
        , gpuDeviceLost = False
        }

modelSessionIdentity ∷ GpuModel → SessionIdentity
modelSessionIdentity = gpuSession

modelDeviceId ∷ GpuModel → DeviceId
modelDeviceId = gpuDevice

modelBudgets ∷ GpuModel → Budgets
modelBudgets = gpuBudgets
