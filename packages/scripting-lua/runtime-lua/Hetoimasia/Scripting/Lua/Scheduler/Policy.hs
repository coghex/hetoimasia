-- | The supplied policy.
module Hetoimasia.Scripting.Lua.Scheduler.Policy
  ( fifoPolicy
  ) where

import qualified Data.List.NonEmpty as NonEmpty
import Hetoimasia.Scripting.Lua.Scheduler.Types
  ( Candidate (candidateTask)
  , Policy (Policy)
  , PolicyView (viewReady)
  , servable
  )

-- | First in, first out among the ready peers of the class being served.
--
-- Ready tasks are ordered by their 'Hetoimasia.Scripting.Lua.Internal.Protocol.Identity.Ordinal',
-- which the runtime issues at admission and again whenever a task rejoins the
-- ready set: a yielded, woken or resumed task is behind everything already
-- ready, and a newly admitted one-shot is appended at its class's tail exactly
-- as a looped task is. Taking the oldest each time is round-robin service at
-- segment boundaries.
fifoPolicy ∷ Policy
fifoPolicy = Policy "fifo" $ \view →
  case servable view of
    candidate : _ → candidateTask candidate
    -- The runtime offers an opportunity only to a class that has a ready task,
    -- so this is not reached; the oldest ready task is a refusable answer.
    [] → candidateTask (NonEmpty.head (viewReady view))
