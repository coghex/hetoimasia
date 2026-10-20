-- | The session's own record of how it is ending: the gameplay script failures it has been told of, whether
-- a stop was asked for, and what has been published (#499 requirements 1, 3, 4, 8 and 9).
--
-- = Ownership
--
-- One transactional variable in the sample's shared state. Its writers are the gameplay owner's thread,
-- through the escalation callback of "Hetoimasia.Sample.LuaDomains.Domains" (a script failure is told to
-- the application there, on the owner's thread, after the instance has ended), the driver, which records
-- a task's fault it finds and everything that follows from a stop, and whoever asks for the stop. Its readers
-- are the driver and the examples. Nothing in it is a Lua value.
--
-- = What a failure is
--
-- A /session failure/ is a failure of script execution on the gameplay owner: an instance at any phase,
-- a fault of a task the session admitted. The failure of application code and a cleanup failure are not: they
-- are an owner failure under its worker policy, and a failure of an instance that is only a failed release
-- is cleanup evidence, fatal under supervision, and is never recorded here ('recordable').
--
-- The first failure is the session's. Later ones are counted and the first few kept, bounded, as secondary
-- evidence. /When the failure snapshot is published/ the count of later failures known at that moment is
-- fixed in it, and it is published once; a failure told of afterwards (a @shutdown@ that raises while the
-- session is stopped, say) is counted and kept for the final report and the cleanup record, and the snapshot
-- is neither republished nor does its primary failure change.
module Hetoimasia.Sample.LuaDomains.Session
  ( SessionState (..)
  , newSessionState
  , recordFailure
  , failureCountNow
  , maxSecondaryKept
  , failedNow
  , evidenceNow
  , markPublished
  , claimEnding
  , requestStopNow
  , stopRequestedNow
  , markEnded
  , Ended (..)
  ) where

import Control.Concurrent.STM (STM, TVar, modifyTVar', newTVarIO, readTVar, retry, writeTVar)
import Hetoimasia.Sample.LuaDomains.Snapshot (FailureEvidence (..), SessionFailure)

-- | How a session ended, once the publication that ends it has been made.
data Ended
  = EndedFailed
  | EndedStopped
  | -- | A finite session ran its last tick and nothing failed: the last tick's snapshot stands, and none was
    -- published for the ending.
    EndedFinished
  deriving (Eq, Show)

-- | The session's record.
data SessionState = SessionState
  { sessionFailures ∷ ![SessionFailure]
    -- ^ The first failure and then up to 'maxSecondaryKept' more, oldest first.
  , sessionFailureCount ∷ !Int
    -- ^ Every session failure told of, kept or not.
  , sessionPublishedLater ∷ !(Maybe Int)
    -- ^ 'Nothing' until the failure snapshot is published; then the later failures it counted.
  , sessionAfter ∷ ![SessionFailure]
    -- ^ The failures told of after the failure snapshot was published, bounded, for the report.
  , sessionStopRequested ∷ !Bool
  , sessionClaimed ∷ !Bool
    -- ^ Some thread has taken the publication that ends the session and has not finished it: any other waits
    -- for it, so the publisher is never closed under it.
  , sessionEnded ∷ !(Maybe Ended)
    -- ^ Set, in the transaction that makes it, by the publication that ends the session.
  }
  deriving (Eq, Show)

newSessionState ∷ IO (TVar SessionState)
newSessionState = newTVarIO (SessionState [] 0 Nothing [] False False Nothing)

-- | How many failures are kept beside the first.
maxSecondaryKept ∷ Int
maxSecondaryKept = 4

-- | Record a session failure. Before the failure snapshot is published it joins the evidence; after, it is
-- counted and kept for the report and changes no snapshot.
recordFailure ∷ TVar SessionState → SessionFailure → STM ()
recordFailure var failure = modifyTVar' var $ \state →
  case sessionPublishedLater state of
    Nothing →
      state
        { sessionFailures = if length (sessionFailures state) <= maxSecondaryKept then sessionFailures state <> [failure] else sessionFailures state
        , sessionFailureCount = sessionFailureCount state + 1
        }
    Just _ →
      state
        { sessionAfter = if length (sessionAfter state) < maxSecondaryKept then sessionAfter state <> [failure] else sessionAfter state
        , sessionFailureCount = sessionFailureCount state + 1
        }

-- | How many session failures have been told of.
failureCountNow ∷ TVar SessionState → STM Int
failureCountNow var = sessionFailureCount <$> readTVar var

-- | Whether a failure has been told of: the session is failed, published or not.
failedNow ∷ TVar SessionState → STM Bool
failedNow var = (> 0) . sessionFailureCount <$> readTVar var

-- | The evidence as it stands: the first failure and the count of later ones known now.
evidenceNow ∷ TVar SessionState → STM (Maybe FailureEvidence)
evidenceNow var = do
  state ← readTVar var
  pure $ case sessionFailures state of
    primary : _ → Just (FailureEvidence primary (sessionFailureCount state - 1))
    [] → Nothing

-- | Say the failure snapshot is being published with this evidence, in the transaction that takes the
-- publication: later failures are counted apart from now on.
markPublished ∷ TVar SessionState → FailureEvidence → STM ()
markPublished var evidence = modifyTVar' var $ \state →
  state {sessionPublishedLater = Just (evidenceLater evidence)}

-- | Take the publication that ends the session, if no other has: answers whether this call has it. It waits for
-- another's to finish first, so what it answers after the wait is that the session has ended.
claimEnding ∷ TVar SessionState → STM Bool
claimEnding var = do
  state ← readTVar var
  case (sessionEnded state, sessionClaimed state) of
    (Just _, _) → pure False
    (Nothing, True) → retry
    (Nothing, False) → True <$ writeTVar var state {sessionClaimed = True}

-- | Ask for a stop. Answers whether this call is the one that asked: a repeated stop asks nothing again.
requestStopNow ∷ TVar SessionState → STM Bool
requestStopNow var = do
  state ← readTVar var
  if sessionStopRequested state
    then pure False
    else True <$ writeTVar var state {sessionStopRequested = True}

stopRequestedNow ∷ TVar SessionState → STM Bool
stopRequestedNow var = sessionStopRequested <$> readTVar var

-- | Say how the session ended, if it has not been said already: a failure that was published keeps
-- being the way it ended, whatever stops it afterwards.
markEnded ∷ TVar SessionState → Ended → STM ()
markEnded var how = modifyTVar' var $ \state → case sessionEnded state of
  Nothing → state {sessionEnded = Just how}
  Just _ → state
