-- | The sample's counters: the intentions' ledger by answer and by disposition (#498 requirement 8, extended by
-- #499 requirements 5 and 6), the UI's control requests (requirement 12), and the workspaces the gameplay
-- instances acquired and released (requirement 10).
--
-- Each is one value in one transactional variable of the sample's shared state. Answers are counted in the
-- transaction that gives them; dispositions in the transaction that commits the tick, or that ends the session,
-- so the two sides of the conservation law are read together in one transaction:
--
-- @accepted = applied + rejected as stale + invalidated by failure + discarded at stop@
--
-- once nothing is pending.
module Hetoimasia.Sample.LuaDomains.Tally
  ( Counts (..)
  , noCounts
  , countFull
  , countAnswer
  , countSettled
  , countInvalidated'
  , countDiscarded'
  , settledTotal
    -- * Controls
  , ControlCounts (..)
  , noControls
  , bumpOffered
  , bumpAnswer
  , bumpSettled
    -- * Workspaces
  , Workspaces (..)
  , noWorkspaces
  ) where

import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import Hetoimasia.Sample.LuaDomains.Intention (Answer (..), FullCause (..))

-- | What has been answered, and what has become of what was accepted.
data Counts = Counts
  { countAccepted ∷ !Int
  , countFullQueue ∷ !Int
    -- ^ Answered full because the queue's bound was reached.
  , countFullPlaces ∷ !Int
    -- ^ Answered full because the tick's places were all taken.
  , countClosed ∷ !Int
  , countRefused ∷ !Int
    -- ^ Over a bound of the application, which the binding answered.
  , countMalformed ∷ !Int
    -- ^ A wrong arity or type, which the facade answered before the binding was reached.
  , countDeclined ∷ !Int
    -- ^ Offered to a session that takes its intentions from an input log alone, and declined: never accepted, and so
    -- given no place and no disposition.
  , countApplied ∷ !Int
  , countStale ∷ !Int
    -- ^ Rejected at their tick, listed or not.
  , countInvalidated ∷ !Int
    -- ^ Accepted and not committed when the session failed.
  , countDiscarded ∷ !Int
    -- ^ Accepted and not committed when a stop ended the session.
  }
  deriving (Eq, Show)

noCounts ∷ Counts
noCounts = Counts 0 0 0 0 0 0 0 0 0 0 0

-- | Every full answer, whatever its cause.
countFull ∷ Counts → Int
countFull counts = countFullQueue counts + countFullPlaces counts

-- | Count one answer. 'Nothing' is a malformed call, which has no 'Answer' of the queue's.
countAnswer ∷ Maybe Answer → Counts → Counts
countAnswer answer counts = case answer of
  Nothing → counts {countMalformed = countMalformed counts + 1}
  Just (Accepted _) → counts {countAccepted = countAccepted counts + 1}
  Just (Full FullQueue) → counts {countFullQueue = countFullQueue counts + 1}
  Just (Full FullPlaces) → counts {countFullPlaces = countFullPlaces counts + 1}
  Just Closed → counts {countClosed = countClosed counts + 1}
  Just (Refused _) → counts {countRefused = countRefused counts + 1}
  Just Declined → counts {countDeclined = countDeclined counts + 1}

-- | Count the dispositions of one committed tick.
countSettled ∷ Int → Int → Counts → Counts
countSettled applied stale counts =
  counts {countApplied = countApplied counts + applied, countStale = countStale counts + stale}

-- | Count the intentions a failure invalidated.
countInvalidated' ∷ Int → Counts → Counts
countInvalidated' n counts = counts {countInvalidated = countInvalidated counts + n}

-- | Count the intentions a stop discarded.
countDiscarded' ∷ Int → Counts → Counts
countDiscarded' n counts = counts {countDiscarded = countDiscarded counts + n}

-- | Everything that has reached a terminal disposition: what the law sets equal to the accepted.
settledTotal ∷ Counts → Int
settledTotal counts = countApplied counts + countStale counts + countInvalidated counts + countDiscarded counts

-- | The UI's requests to pause and resume gameplay, and what became of each.
data ControlCounts = ControlCounts
  { controlOffered ∷ !Int
    -- ^ Requests made.
  , controlAccepted ∷ !Int
    -- ^ Requests with a place for the next tick that had not begun.
  , controlRefused ∷ !(Map Text Int)
    -- ^ Requests refused at once, by the engine's reason.
  , controlApplied ∷ !Int
  , controlAlready ∷ !Int
    -- ^ Settled as already in that state.
  , controlNoLonger ∷ !Int
    -- ^ Settled as no longer applicable.
  , controlAbandoned ∷ !Int
    -- ^ Receipts the UI held, unread, when it ended: reported apart, never given a result.
  }
  deriving (Eq, Show)

noControls ∷ ControlCounts
noControls = ControlCounts 0 0 Map.empty 0 0 0 0

bumpOffered ∷ ControlCounts → ControlCounts
bumpOffered counts = counts {controlOffered = controlOffered counts + 1}

-- | Count the engine's answer to a request: accepted, or refused for this reason.
bumpAnswer ∷ Maybe Text → ControlCounts → ControlCounts
bumpAnswer reason counts = case reason of
  Nothing → counts {controlAccepted = controlAccepted counts + 1}
  Just why → counts {controlRefused = Map.insertWith (+) why 1 (controlRefused counts)}

-- | Count one accepted request's settlement, by the engine's word for it.
bumpSettled ∷ Text → ControlCounts → ControlCounts
bumpSettled kind counts = case kind of
  "applied" → counts {controlApplied = controlApplied counts + 1}
  "already_in_state" → counts {controlAlready = controlAlready counts + 1}
  _ → counts {controlNoLonger = controlNoLonger counts + 1}

-- | The gameplay instances' workspaces: acquired, and what became of each.
data Workspaces = Workspaces
  { workspacesAcquired ∷ !Int
  , workspacesReleased ∷ !Int
    -- ^ Releases that completed.
  , workspacesReleaseFailed ∷ !Int
    -- ^ Releases that were attempted and failed: not reclaimed, and never counted as released.
  }
  deriving (Eq, Show)

noWorkspaces ∷ Workspaces
noWorkspaces = Workspaces 0 0 0
