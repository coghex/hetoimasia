-- | The one scheduling rule, and the wrappers every transition applies it
-- through.
--
-- This module owns when a transition resets the owner's polling backoff. It
-- decides that from the work summary in "Hetoimasia.GPU.Model.Internal.Work" and from what
-- a transition declares, and it is the only place the decision is made: a
-- transition never resets the backoff by hand.
module Hetoimasia.GPU.Model.Internal.Scheduling
  ( settleSchedule
  , scheduling
  , scheduling_
  , observing_
  ) where

import Hetoimasia.GPU.Model.Internal.Recovery (resetBackoff)
import Hetoimasia.GPU.Model.Internal.State (GpuModel (..), Outcome)
import Hetoimasia.GPU.Model.Internal.Work (work, workGrew)

-- | Reset the owner's polling backoff to request an immediate progress
-- opportunity. This changes scheduling state; it performs no progress work.
roused ∷ GpuModel → GpuModel
roused model = model {gpuBackoff = resetBackoff (gpuBackoff model)}

-- | The one scheduling rule, applied to every transition.
--
-- The owner-progress contract names four things that restart the schedule:
-- new demand, a new obligation, an observed completion, and a close. The first
-- two mean "the owner has more to do than before", decided by comparing the
-- work summary rather than by remembering to call something at each site —
-- the previous arrangement, where two dozen transitions each reset the backoff
-- by hand, is the one that let a replacement request slip through unscheduled.
-- The other two are not visible in that comparison, since a completion reduces
-- the work and a close can too, so a transition declares them.
--
-- An observation, or a transition that only removed work, leaves the anchored
-- deadline exactly where it was.
settleSchedule ∷ Bool → GpuModel → GpuModel → GpuModel
settleSchedule observed before after
  | observed || workGrew (work before) (work after) = roused after
  | otherwise = after

-- | Apply the rule to a transition that answers a model and a value.
scheduling ∷ GpuModel → Outcome (GpuModel, a) → Outcome (GpuModel, a)
scheduling before = fmap (\(after, value) → (settleSchedule False before after, value))

-- | The same, for a transition that answers a model alone.
scheduling_ ∷ GpuModel → Outcome GpuModel → Outcome GpuModel
scheduling_ before = fmap (settleSchedule False before)

-- | Apply the rule to an observed completion or a close, which request an
-- immediate progress opportunity even when the work summary does not grow.
observing_ ∷ GpuModel → Outcome GpuModel → Outcome GpuModel
observing_ before = fmap (settleSchedule True before)
