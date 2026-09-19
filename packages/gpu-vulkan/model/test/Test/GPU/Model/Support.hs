-- | Fixtures the GPU model's examples share.
--
-- Everything here is deterministic. Instants come from the foundation's
-- scripted domain rather than from a clock, and no example sleeps: ordering is
-- established by the sequence of calls, which is the only thing the model can
-- observe anyway.
--
-- The unwrapping helpers fail the example with the answer they actually got, so
-- an unexpected backpressure never reads as an unexpected misuse and neither
-- reads as a pattern-match failure with no context.
module Test.GPU.Model.Support
  ( -- * Building a model
    freshModel
  , freshModelWith
  , smallRequest

    -- * Unwrapping answers
  , admitted
  , admitted_
  , backpressured
  , rejected
  , rejected_

    -- * Scripted time
  , atMilliseconds
  , afterMilliseconds
  , millisecondsDuration

    -- * Common arrangements
  , activeTarget
  , activeTargetWith
  , acquiredFrame
  , aResource
  ) where

import Data.Unique (newUnique)
import GHC.Stack (HasCallStack)
import Hetoimasia.Foundation.Time
  ( Duration
  , DurationRequirement (AllowZero)
  , Instant
  , durationFromNanoseconds
  , scriptedInstant
  )
import Hetoimasia.GPU.Model
import Hetoimasia.GPU.Model.Budget
import Hetoimasia.GPU.Model.Identity
import Numeric.Natural (Natural)

-- ---------------------------------------------------------------------------
-- Building a model

-- | A session with the proposed defaults: 16 target records, 2 frame slots per
-- target within an aggregate of 32, 2 generations per target, 16 tracked images
-- and therefore a presentation pool of 18, 256 MiB, 4,096 objects, 64 examined
-- records per reclaim pass, 32 actions per turn and a 100 ms backoff cap.
freshModel ∷ HasCallStack ⇒ IO GpuModel
freshModel = freshModelWith defaultBudgetRequest

freshModelWith ∷ HasCallStack ⇒ BudgetRequest → IO GpuModel
freshModelWith request = do
  unique ← newUnique
  budgets ← either (fail . ("the fixture configuration is invalid: " ++) . show) pure (validateBudgets request)
  pure (fst (newGpuModel (sessionIdentity unique) budgets))

-- | Deliberately small budgets, as P-15 asks a test fixture to choose, so an
-- example can reach an exhausted budget in a handful of calls rather than
-- hundreds.
smallRequest ∷ BudgetRequest
smallRequest =
  defaultBudgetRequest
    { requestedTargetRecords = 2
    , requestedFrameSlots = 1
    , requestedAggregateFrameSlots = 2
    , requestedGenerations = 2
    , requestedImageTracking = 2
    , requestedBytes = 4096
    , requestedObjects = 64
    , requestedReclaimExamination = 2
    , requestedProgressActions = 2
    }

-- ---------------------------------------------------------------------------
-- Unwrapping answers

admitted ∷ HasCallStack ⇒ String → Outcome a → IO a
admitted label = \case
  Admitted value → pure value
  Backpressure kind → fail (label ++ " should have been admitted, but the answer was backpressure on " ++ show kind)
  Rejected misuse → fail (label ++ " should have been admitted, but the answer was misuse " ++ show misuse)

admitted_ ∷ HasCallStack ⇒ String → Outcome GpuModel → IO GpuModel
admitted_ = admitted

backpressured ∷ HasCallStack ⇒ String → Outcome a → IO BudgetKind
backpressured label = \case
  Backpressure kind → pure kind
  Admitted _ → fail (label ++ " should have been refused as backpressure, but it was admitted")
  Rejected misuse → fail (label ++ " should have been refused as backpressure, but the answer was misuse " ++ show misuse)

rejected ∷ HasCallStack ⇒ String → Outcome a → IO Misuse
rejected label = \case
  Rejected misuse → pure misuse
  Admitted _ → fail (label ++ " should have been rejected as misuse, but it was admitted")
  Backpressure kind → fail (label ++ " should have been rejected as misuse, but the answer was backpressure on " ++ show kind)

rejected_ ∷ HasCallStack ⇒ String → Outcome GpuModel → IO Misuse
rejected_ = rejected

-- ---------------------------------------------------------------------------
-- Scripted time

-- | An instant that many whole milliseconds after the script's own origin.
atMilliseconds ∷ Natural → Instant
atMilliseconds = scriptedInstant . durationOf

-- | The same, written where a reader should see an interval rather than a date.
afterMilliseconds ∷ Natural → Instant
afterMilliseconds = atMilliseconds

-- | A duration of that many whole milliseconds.
millisecondsDuration ∷ Natural → Duration
millisecondsDuration = durationOf

durationOf ∷ Natural → Duration
durationOf value =
  either
    (\reason → error ("the fixture asked for an impossible duration: " ++ show reason))
    id
    (durationFromNanoseconds AllowZero (toInteger value * 1000000))

-- ---------------------------------------------------------------------------
-- Common arrangements

-- | A target with one published generation of the given image count.
activeTarget ∷ HasCallStack ⇒ Natural → GpuModel → IO (GpuModel, TargetId, GenerationId)
activeTarget = activeTargetWith OptionalTarget

activeTargetWith ∷ HasCallStack ⇒ TargetClass → Natural → GpuModel → IO (GpuModel, TargetId, GenerationId)
activeTargetWith classification images model = do
  (withTarget, target) ← admitted "admitting a target" (admitTarget classification model)
  (constructing, generation) ← admitted "beginning a generation" (beginGeneration target Nothing withTarget)
  (published, answer) ← admitted "publishing a generation" (publishGeneration generation images constructing)
  case answer of
    GenerationPublished _ → pure (published, target, generation)
    other → fail ("the fixture's generation should have published, but the answer was " ++ show other)

-- | A frame of that target holding the lowest image of its active generation
-- that no live presentation record already owns.
--
-- The index is searched rather than fixed, because an image belongs to one owner
-- at a time and a record can outlive its frame: a fixture that always asked for
-- image zero would be asking for an image the previous frame's record still owes
-- a retirement on. A presentation engine does not hand the same image out twice
-- either, so this is the realistic fixture as well as the admissible one.
acquiredFrame ∷ HasCallStack ⇒ TargetId → GpuModel → IO (GpuModel, FrameSlotId)
acquiredFrame target model = do
  (reserved, frame) ← admitted "reserving a frame" (reserveFrame target model)
  let attempt index = case acquireImage frame (AcquiredImage index) reserved of
        Rejected (AlreadyConsumed ImageIdentity) → attempt (index + 1)
        Rejected (UnknownIdentity ImageIdentity) →
          fail "the fixture's target has no free image left to acquire"
        answered → do
          (acquired, answer) ← admitted "acquiring an image" answered
          case answer of
            ImageOwned _ _ → pure (acquired, frame)
            other → fail ("the fixture's acquisition should have owned an image, but the answer was " ++ show other)
  attempt (0 ∷ Natural)

-- | One managed resource, through the allocation attempt that reserved it.
aResource ∷ HasCallStack ⇒ Natural → GpuModel → IO (GpuModel, ResourceId)
aResource bytes model = do
  (reserved, allocation) ← admitted "reserving an allocation" (beginAllocation bytes 1 model)
  admitted "creating a resource" (createResource allocation reserved)
