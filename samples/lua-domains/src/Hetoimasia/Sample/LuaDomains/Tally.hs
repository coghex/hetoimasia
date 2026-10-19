-- | The sample's counters, by answer and by disposition (requirement 8).
--
-- One value in one transactional variable, owned by the sample's shared state. Answers are counted
-- in the transaction that gives them; dispositions in the transaction that commits the tick, so
-- the two sides of the conservation law — accepted equals applied plus stale, once nothing is
-- pending — are read together in one transaction.
module Hetoimasia.Sample.LuaDomains.Tally
  ( Counts (..)
  , noCounts
  , countAnswer
  , countSettled
  ) where

import Hetoimasia.Sample.LuaDomains.Intention (Answer (..))

-- | What has been answered, and what has become of what was accepted.
data Counts = Counts
  { countAccepted ∷ !Int
  , countFull ∷ !Int
  , countClosed ∷ !Int
  , countRefused ∷ !Int
    -- ^ Over a bound of the application, which the binding answered.
  , countMalformed ∷ !Int
    -- ^ A wrong arity or type, which the facade answered before the binding was reached.
  , countApplied ∷ !Int
  , countStale ∷ !Int
    -- ^ Rejected at their tick, listed or not.
  }
  deriving (Eq, Show)

noCounts ∷ Counts
noCounts = Counts 0 0 0 0 0 0 0

-- | Count one answer. 'Nothing' is a malformed call, which has no 'Answer' of the queue's.
countAnswer ∷ Maybe Answer → Counts → Counts
countAnswer answer counts = case answer of
  Nothing → counts {countMalformed = countMalformed counts + 1}
  Just (Accepted _) → counts {countAccepted = countAccepted counts + 1}
  Just Full → counts {countFull = countFull counts + 1}
  Just Closed → counts {countClosed = countClosed counts + 1}
  Just (Refused _) → counts {countRefused = countRefused counts + 1}

-- | Count the dispositions of one committed tick.
countSettled ∷ Int → Int → Counts → Counts
countSettled applied stale counts =
  counts {countApplied = countApplied counts + applied, countStale = countStale counts + stale}
