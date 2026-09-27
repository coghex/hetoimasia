-- | The recovery policy, outcome and history types, and the private annotation
-- that carries a history on a propagated failure.
--
-- 'Disposition', 'Strategy', 'RecoveryPolicy', 'InvalidRecoveryPolicy',
-- 'Outcome', 'Recovered', 'Unavailability', 'AttemptFailure', 'AttemptKind',
-- and 'RecoveryHistory' are the public types "Hetoimasia.Foundation.Recovery"
-- re-exports. 'HistoryEntry' is the annotation both of that module's recovery
-- boundaries attach and its history inspection reads back; its
-- 'ExceptionAnnotation' instance and the rendering that instance needs live
-- here with it. The public module does not export 'HistoryEntry', so history
-- can only be attached by 'Hetoimasia.Foundation.Recovery.recover' and
-- 'Hetoimasia.Foundation.Recovery.allocComponent'. This module is private to
-- the foundation package.
--
-- 'Operation' comes from "Hetoimasia.Foundation.Failure.Base" directly, so the
-- recovery types depend on neither failure annotations nor the recovery loop.
module Hetoimasia.Foundation.Recovery.Types
  ( -- * Policy
    Disposition (..)
  , Strategy (..)
  , RecoveryPolicy (..)
  , InvalidRecoveryPolicy (..)

    -- * Outcomes
  , AttemptKind (..)
  , AttemptFailure (..)
  , Recovered (..)
  , Unavailability (..)
  , Outcome (..)

    -- * History
  , RecoveryHistory (..)
  , HistoryEntry (..)
  ) where

import Control.Exception (Exception, ExceptionWithContext, SomeException)
import Control.Exception.Annotation (ExceptionAnnotation (displayExceptionAnnotation))
import Data.List (intercalate)
import Hetoimasia.Foundation.Failure.Base (Operation, operationText)

-- | Whether the caller can continue without the operation's result.
--
-- This is the caller's decision for one named operation, never a severity
-- attached to an exception type.
data Disposition
  = Required
    -- ^ Exhaustion propagates the latest failure.
  | Optional
    -- ^ Exhaustion of a recognized failure returns 'Unavailable'.
  deriving (Eq, Show)

-- | What to run next after a recognized failure.
data Strategy a
  = Retry
    -- ^ Run the operation given to 'Hetoimasia.Foundation.Recovery.recover'
    -- again, even after a fallback.
  | Fallback !Operation (IO a)
    -- ^ Run the named alternative operation.

-- | Which operation an attempt ran.
data AttemptKind
  = InitialAttempt
  | RetryAttempt
  | FallbackAttempt !Operation
  deriving (Eq, Show)

-- | One attempt that failed synchronously after its cleanup finished.
data AttemptFailure = AttemptFailure
  { attemptNumber ∷ !Int
    -- ^ One for the initial attempt, counting every retry and fallback.
  , attemptKind ∷ !AttemptKind
  , attemptException ∷ !(ExceptionWithContext SomeException)
    -- ^ The failure with the context it propagated with, so its origin and
    -- cleanup evidence stay inspectable.
  }
  deriving (Show)

-- | The explicit recovery policy for one named operation.
--
-- There is no default: a caller states which failures its component can
-- handle, how, how many attempts in total are allowed, and whether the work is
-- required.
data RecoveryPolicy a = RecoveryPolicy
  { policyDisposition ∷ Disposition
  , policyBudget ∷ Int
    -- ^ The total number of attempts, the initial one included. Must be
    -- positive.
  , policyClassifier ∷ AttemptFailure → IO (Maybe (Strategy a))
    -- ^ Supplied by the component that knows its failures. 'Nothing' means the
    -- failure is not recognized and propagates. It sees only synchronous
    -- failures whose attempt retained no cleanup evidence, and it is consulted
    -- for the last attempt too, so an unrecognized failure is never downgraded
    -- to 'Unavailable'.
  , policyWait ∷ Int → IO ()
    -- ^ Runs before each later attempt, given that attempt's number, after the
    -- failed attempt's cleanup and outside every release. It runs with the
    -- caller's masking state, so a blocking wait stays cancellable.
  }

-- | A policy 'Hetoimasia.Foundation.Recovery.recover' refuses before running
-- anything.
newtype InvalidRecoveryPolicy = NonPositiveBudget Int
  deriving (Eq, Show)

instance Exception InvalidRecoveryPolicy

-- | A successful attempt's result.
data Recovered a = Recovered
  { recoveredValue ∷ a
  , recoveredBy ∷ !AttemptKind
    -- ^ 'InitialAttempt' when no recovery was needed.
  , recoveredFailures ∷ ![AttemptFailure]
    -- ^ Every failed attempt before the successful one, oldest first.
  }

-- | Why optional work is unavailable.
data Unavailability = Unavailability
  { unavailableOperation ∷ !Operation
  , unavailableReason ∷ !AttemptFailure
    -- ^ The last attempt, which the classifier recognized with no budget left.
  , unavailableEarlier ∷ ![AttemptFailure]
    -- ^ Every attempt before it, oldest first.
  }
  deriving (Show)

-- | What 'Hetoimasia.Foundation.Recovery.recover' returns.
data Outcome a
  = Available !(Recovered a)
  | Unavailable !Unavailability
    -- ^ Only for an 'Optional' policy.

-- | The earlier failed attempts of one recovery, attached to the failure that
-- ended it.
data RecoveryHistory = RecoveryHistory
  { historyOperation ∷ !Operation
  , historyAttempts ∷ ![AttemptFailure]
    -- ^ Oldest first; the propagated failure itself is not repeated here.
  }
  deriving (Show)

-- | The annotation both recovery boundaries attach. It is not exported from
-- "Hetoimasia.Foundation.Recovery", so history is only attached by
-- 'Hetoimasia.Foundation.Recovery.recover' and
-- 'Hetoimasia.Foundation.Recovery.allocComponent', and no client can build or
-- read one directly. The position orders entries by attachment, as
-- "Hetoimasia.Foundation.Failure" does for its own evidence.
data HistoryEntry = HistoryEntry !Int !RecoveryHistory

instance ExceptionAnnotation HistoryEntry where
  displayExceptionAnnotation (HistoryEntry _ history) =
    "after failed recovery attempts of "
      <> show (operationText (historyOperation history))
      <> ": "
      <> intercalate ", " (map describeAttempt (historyAttempts history))

-- | One attempt on one line. Operation names are rendered with 'show', which
-- escapes quotes and control characters, and no exception text is rendered.
describeAttempt ∷ AttemptFailure → String
describeAttempt failure =
  "#" <> show (attemptNumber failure) <> " " <> case attemptKind failure of
    InitialAttempt → "initial"
    RetryAttempt → "retry"
    FallbackAttempt name → "fallback " <> show (operationText name)
