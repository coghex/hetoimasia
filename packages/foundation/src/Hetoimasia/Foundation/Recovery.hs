-- | Bounded, classified recovery around one complete owned operation.
--
-- 'recover' runs an 'IO' operation under a 'RecoveryPolicy' its caller supplies
-- for that named operation, and either returns a truthful 'Outcome' or
-- propagates a preserved failure. The operation is complete and owned: every
-- scope it opens is inside it, so an attempt includes every inner scope's
-- release obligations, and a failed attempt has finished its cleanup before
-- anything else happens. Scopes enclosing the boundary are not touched and
-- remain usable afterwards.
--
-- Each failed attempt is handled in this order:
--
-- 1. The attempt has already unwound, so its releases have been attempted.
-- 2. Cancellation — anything in the 'SomeAsyncException' hierarchy — propagates
--    as itself, with its existing context and cleanup evidence and nothing
--    added. It is never retried, never made unavailable, and never replaced by
--    an earlier synchronous failure.
-- 3. A failure carrying retained cleanup evidence (see
--    'Hetoimasia.Foundation.Resource.cleanupFailuresInContext') propagates.
--    An attempted release is not proof of disposal, so no retry or fallback
--    follows it, and no override exists here that treats that cleanup as
--    complete.
-- 4. Only then is the policy's classifier consulted. A failure it does not
--    recognize propagates.
-- 5. A recognized failure with budget remaining runs the policy's wait and then
--    the selected strategy: the original operation again, or a named fallback.
-- 6. A recognized failure with no budget left propagates if the operation is
--    'Required'. If the caller declared it 'Optional', 'recover' returns
--    'Unavailable' with the reason and every failed attempt.
--
-- One finite budget counts the initial attempt and every retry and fallback,
-- and switching strategy never resets it. A policy whose budget is not positive
-- is rejected with 'InvalidRecoveryPolicy' before the operation, the
-- classifier, or the wait runs.
--
-- A failure that propagates after earlier attempts failed keeps its own type,
-- value, and context — its origin evidence and its cleanup evidence included —
-- with one 'RecoveryHistory' annotation added that lists those earlier attempts
-- in order, each with its own context. The terminal cause is never replaced by
-- a generic exhaustion value. A failure on the first attempt propagates with
-- nothing added.
--
-- A failure raised by the classifier or the wait stops recovery at once. It is
-- not classified, and it propagates with the failure being handled attached as
-- a 'WhileHandling' annotation, the convention a @catch@ handler follows.
--
-- The boundary's extent is exactly the operation it was given. Code the caller
-- runs after 'recover' returns is outside it: a failure there is neither caught
-- nor retried, and that code runs once. This module adds no catch instance to
-- 'Hetoimasia.Foundation.Resource.Scoped'.
--
-- What recovery does not do: cleanup does not undo 'Data.IORef.IORef' writes,
-- consumed messages, or external effects, and it does not make an operation
-- idempotent. A policy may select 'Retry' only for an operation that has
-- restored, or never disturbed, the state its next attempt relies on, and
-- 'Fallback' only for an alternative that is valid from the state the failed
-- attempt left. An operation with no established safe replay must not be
-- given a policy that replays it. A fallback that must hand a live replacement
-- service to the rest of the application is not this API: the result leaving
-- 'recover' is an ordinary value, evaluated to weak head normal form inside
-- the attempt, and never a handle whose owning scope has closed.
--
-- The boundary takes no logger and emits no diagnostics. The 'Outcome' and the
-- 'RecoveryHistory' carry what a reporting adapter needs to explain what
-- happened.
--
-- See @docs/recovery.md@ for the same contract in prose.
module Hetoimasia.Foundation.Recovery
  ( -- * Boundary
    recover

    -- * Policy
  , RecoveryPolicy (..)
  , Disposition (..)
  , Strategy (..)
  , InvalidRecoveryPolicy (..)

    -- * Outcomes
  , Outcome (..)
  , Recovered (..)
  , Unavailability (..)
  , AttemptFailure (..)
  , AttemptKind (..)

    -- * History on a propagated failure
  , RecoveryHistory (..)
  , recoveryHistory
  , recoveryHistoryInContext
  ) where

import Control.Exception
  ( Exception
  , ExceptionWithContext (ExceptionWithContext)
  , SomeAsyncException
  , SomeException
  , WhileHandling (WhileHandling)
  , evaluate
  , fromException
  , rethrowIO
  , someExceptionContext
  , throwIO
  , toException
  , tryWithContext
  )
import Control.Exception.Annotation (ExceptionAnnotation (displayExceptionAnnotation))
import Control.Exception.Context
  ( ExceptionContext
  , addExceptionAnnotation
  , getExceptionAnnotations
  )
import Control.Monad (when)
import Data.List (intercalate, sortOn)
import Data.Maybe (isJust)
import Hetoimasia.Foundation.Failure (Operation, operationText)
import Hetoimasia.Foundation.Resource (cleanupFailuresInContext)

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
    -- ^ Run the operation given to 'recover' again, even after a fallback.
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

-- | A policy 'recover' refuses before running anything.
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

-- | What 'recover' returns.
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

-- | The annotation this module attaches. It is not exported, so history is only
-- attached by 'recover'. The position orders entries by attachment, as
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

-- | Run one complete owned operation under a recovery policy.
--
-- The policy's fields are evaluated and its budget validated before the
-- operation runs; an invalid budget throws 'InvalidRecoveryPolicy' and nothing
-- else happens.
recover ∷ Operation → RecoveryPolicy a → IO a → IO (Outcome a)
recover name policy action = do
  _ ← evaluate (operationText name)
  disposition ← evaluate (policyDisposition policy)
  budget ← evaluate (policyBudget policy)
  classifier ← evaluate (policyClassifier policy)
  wait ← evaluate (policyWait policy)
  when (budget < 1) $ throwIO (NonPositiveBudget budget)
  let attempt number kind operationToRun earlier = do
        outcome ← tryWithContext (operationToRun >>= evaluate)
        case outcome of
          Right value → pure (Available (Recovered value kind (reverse earlier)))
          Left failed@(ExceptionWithContext context exception)
            | isCancellation exception → rethrowIO failed
            | not (null (cleanupFailuresInContext context)) → rethrowIO handled
            | otherwise → do
                selected ← guarded handled (classifier failure >>= evaluateStrategy)
                case selected of
                  Nothing → rethrowIO handled
                  Just strategy
                    | number >= budget → case disposition of
                        Required → rethrowIO handled
                        Optional → pure (Unavailable (Unavailability name failure (reverse earlier)))
                    | otherwise → do
                        guarded handled (wait (number + 1))
                        case strategy of
                          Retry → attempt (number + 1) RetryAttempt action (failure : earlier)
                          Fallback fallbackName fallback →
                            attempt (number + 1) (FallbackAttempt fallbackName) fallback (failure : earlier)
            where
              failure = AttemptFailure number kind failed
              handled = withHistory name earlier failed
  attempt 1 InitialAttempt action []

-- | Evaluate a selected strategy, so a faulting selection is a policy failure
-- rather than a later surprise.
evaluateStrategy ∷ Maybe (Strategy a) → IO (Maybe (Strategy a))
evaluateStrategy selection = do
  selected ← evaluate selection
  case selected of
    Nothing → pure Nothing
    Just strategy → Just <$> evaluate strategy

-- | Run one step of the policy machinery while a failure is being handled.
--
-- A cancellation propagates as itself. Any other failure stops recovery: it is
-- rethrown with its own context and the handled failure attached as
-- 'WhileHandling'.
guarded ∷ ExceptionWithContext SomeException → IO b → IO b
guarded handled step = do
  outcome ← tryWithContext step
  case outcome of
    Right value → pure value
    Left failed@(ExceptionWithContext context exception)
      | isCancellation exception → rethrowIO failed
      | otherwise →
          rethrowIO
            ( ExceptionWithContext
                (addExceptionAnnotation (WhileHandling (toException handled)) context)
                exception
            )

-- | Attach the earlier attempts, oldest first, unless there were none.
withHistory
  ∷ Operation
  → [AttemptFailure]
  → ExceptionWithContext SomeException
  → ExceptionWithContext SomeException
withHistory _ [] failed = failed
withHistory name earlier (ExceptionWithContext context exception) =
  ExceptionWithContext (addExceptionAnnotation entry context) exception
  where
    position = length (getExceptionAnnotations context ∷ [HistoryEntry])
    entry = HistoryEntry position (RecoveryHistory name (reverse earlier))

-- | The recovery histories attached to a failure a caller caught, innermost
-- boundary first. Empty when the failure ended its recovery on its first
-- attempt or never passed through 'recover'.
--
-- History attached to a failure nested inside a 'WhileHandling' annotation is
-- read from that nested exception, not from this one.
recoveryHistory ∷ SomeException → [RecoveryHistory]
recoveryHistory = recoveryHistoryInContext . someExceptionContext

-- | 'recoveryHistory' for a caller holding the context directly.
recoveryHistoryInContext ∷ ExceptionContext → [RecoveryHistory]
recoveryHistoryInContext context =
  [history | HistoryEntry _ history ← sortOn position (getExceptionAnnotations context)]
  where
    position (HistoryEntry index _) = index

isCancellation ∷ SomeException → Bool
isCancellation exception = isJust (fromException exception ∷ Maybe SomeAsyncException)
