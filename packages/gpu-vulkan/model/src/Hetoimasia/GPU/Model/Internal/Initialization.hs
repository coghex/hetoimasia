-- | Image initialization (GRS-3, D-26): a new image is unusable until the
-- batch that initializes it has been submitted.
--
-- This module owns each resource generation's 'InitializationState': marking
-- a new image as awaiting initialization, admitting a batch's first touch of a
-- resource against it, publishing it when a submission is confirmed, and
-- withdrawing a dropped batch's claim. Recording, sealing, a fence reset and
-- a submission that failed — with no effect, or with an effect nobody can
-- know — never publish it, and nothing here changes any resource's resting
-- use, which is its kind's ("Hetoimasia.GPU.Model.Internal.Access").
module Hetoimasia.GPU.Model.Internal.Initialization
  ( Initialization (..)
  , requireInitialization
  , enterResource
  , resourceInitialization
  , withdrawInitialization
  , publishInitialization
  ) where

import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Hetoimasia.GPU.Model.Internal.Access (Contents (..))
import Hetoimasia.GPU.Model.Internal.Hold (Holds (..))
import Hetoimasia.GPU.Model.Internal.Identity
import Hetoimasia.GPU.Model.Internal.Records
import Hetoimasia.GPU.Model.Internal.Resolve (resolveBatch, resolveResource, targetIdOf)
import Hetoimasia.GPU.Model.Internal.Scheduling (scheduling_)
import Hetoimasia.GPU.Model.Internal.State
import Numeric.Natural (Natural)

-- | Whether a resource generation's contents may be used, as an observer
-- sees it.
data Initialization
  = InitializationNotRequired
    -- ^ Not an image awaiting one: usable from its creation.
  | Uninitialized
    -- ^ No batch that initializes it is recorded: the next batch to touch it
    -- must initialize it.
  | InitializingIn !BatchId
    -- ^ This batch initializes it and has not been submitted: no other batch
    -- may use it.
  | Initialized
    -- ^ The batch that initialized it was submitted.
  deriving (Eq, Show)

-- | Mark a new image generation as awaiting initialization. It must not have
-- been marked already, and no batch or submission may have named it.
requireInitialization ∷ ResourceId → GpuModel → Outcome GpuModel
requireInitialization identity model =
  scheduling_ model $
  resolved (running model) $ \() →
    resolved (resolveResource model identity) $ \(key, record) →
      if resourceInitializationState record /= NoInitialization
        then Rejected (AlreadyConsumed ResourceIdentity)
        else
          let holds = resourceHolds record
           in if not (Set.null (recordedReferences holds) && Set.null (submittedUses holds))
                then Rejected (WrongPhase ResourceIdentity)
                else Admitted (setState key AwaitingInitialization model)

-- | A batch's first touch of a resource it already retains, keeping or
-- discarding its contents. An image awaiting initialization admits only a
-- touch that discards — the batch then initializes it — and an image another
-- unsubmitted batch initializes admits none; anything else is admitted
-- unchanged. A refusal is 'WrongPhase' of the resource, and changes nothing.
enterResource ∷ BatchId → ResourceId → Contents → GpuModel → Outcome GpuModel
enterResource batch identity contents model =
  scheduling_ model $
  resolved (running model) $ \() →
    resolved (resolveBatch model batch) $ \(number, record) →
      resolved (resolveResource model identity) $ \(key@(logical, generation), resource) →
        if not (ResourceKey logical generation `Set.member` batchSubjects record)
          then Rejected (WrongParent ResourceIdentity)
          else case (resourceInitializationState resource, contents) of
            (NoInitialization, _) → Admitted model
            (InitializationSubmitted, _) → Admitted model
            (AwaitingInitialization, DiscardsContents) → Admitted (setState key (InitializingBatch number) model)
            (AwaitingInitialization, KeepsContents) → Rejected (WrongPhase ResourceIdentity)
            (InitializingBatch initializer, _)
              | initializer == number → Admitted model
              | otherwise → Rejected (WrongPhase ResourceIdentity)

-- | Where a resource generation's initialization stands, while the model
-- holds it.
resourceInitialization ∷ ResourceId → GpuModel → Maybe Initialization
resourceInitialization identity model = case resolveResource model identity of
  Left _ → Nothing
  Right (_, record) → Just $ case resourceInitializationState record of
    NoInitialization → InitializationNotRequired
    AwaitingInitialization → Uninitialized
    InitializationSubmitted → Initialized
    InitializingBatch number → case Map.lookup number (gpuBatches model) of
      Just batch
        | Just target ← Map.lookup (batchTargetNumber batch) (gpuTargets model) →
            InitializingIn (BatchId (targetIdOf model (batchTargetNumber batch) target) number)
      _ → Uninitialized

-- | A batch is dropped without being submitted — discarded, reset or skipped
-- — or its submission's effect is unknown: whatever it was initializing awaits
-- initialization again.
withdrawInitialization ∷ Natural → Batch → GpuModel → GpuModel
withdrawInitialization number batch model = foldl' withdraw model (Set.toList (batchSubjects batch))
  where
    withdraw current = \case
      ResourceKey logical generation
        | Just record ← Map.lookup (logical, generation) (gpuResources current)
        , resourceInitializationState record == InitializingBatch number →
            setState (logical, generation) AwaitingInitialization current
      _ → current

-- | A submission carrying this batch was confirmed: whatever it initializes
-- is initialized.
publishInitialization ∷ Natural → Batch → GpuModel → GpuModel
publishInitialization number batch model = foldl' publish model (Set.toList (batchSubjects batch))
  where
    publish current = \case
      ResourceKey logical generation
        | Just record ← Map.lookup (logical, generation) (gpuResources current)
        , resourceInitializationState record == InitializingBatch number →
            setState (logical, generation) InitializationSubmitted current
      _ → current

setState ∷ (Natural, Natural) → InitializationState → GpuModel → GpuModel
setState key state model =
  model {gpuResources = Map.adjust (\record → record {resourceInitializationState = state}) key (gpuResources model)}
