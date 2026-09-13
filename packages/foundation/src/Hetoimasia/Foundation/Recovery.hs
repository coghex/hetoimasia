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
-- service to the rest of the application is not 'recover': the result leaving
-- 'recover' is an ordinary value, evaluated to weak head normal form inside
-- the attempt, and never a handle whose owning scope has closed.
--
-- 'allocComponent' is the second boundary, for exactly that case. It selects a
-- live component among 'Hetoimasia.Foundation.Resource.Assembly' alternatives
-- under the same 'RecoveryPolicy', the same attempt order, the same budget,
-- and the same evidence, and binds the result as immutable 'Outcome' data in a
-- 'Hetoimasia.Foundation.Resource.Scoped' value. The two boundaries own
-- different lifetimes: 'recover' finishes every scope inside its operation,
-- while 'allocComponent' keeps the selected attempt's parts alive for the rest
-- of the enclosing scope and never calls 'recover'.
--
-- The boundary takes no logger and emits no diagnostics. The 'Outcome' and the
-- 'RecoveryHistory' carry what a reporting adapter needs to explain what
-- happened.
--
-- See @docs/recovery.md@ for the same contract in prose.
module Hetoimasia.Foundation.Recovery
  ( -- * Boundary
    recover

    -- * Scoped component construction
  , allocComponent

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
  , mask
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
import Control.Monad (join, when)
import Data.List (intercalate, sortOn)
import Data.Maybe (isJust)
import Hetoimasia.Foundation.Failure (Operation, operationText)
import Hetoimasia.Foundation.Resource (Assembly, cleanupFailuresInContext)
import Hetoimasia.Foundation.Resource.Internal
  ( Scoped (Scoped)
  , assemble
  , lendAssembled
  , restoredStep
  , retainCleanupFailures
  )

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
  ValidatedPolicy disposition budget classifier wait ← validatePolicy name policy
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

-- | A policy whose fields have been evaluated and whose budget is positive.
data ValidatedPolicy a
  = ValidatedPolicy
      !Disposition
      !Int
      !(AttemptFailure → IO (Maybe (Strategy a)))
      !(Int → IO ())

-- | Evaluate the operation name and every policy field, and reject a budget
-- below one with 'InvalidRecoveryPolicy'. Both boundaries run this before
-- anything else, so an invalid policy causes no effect.
validatePolicy ∷ Operation → RecoveryPolicy a → IO (ValidatedPolicy a)
validatePolicy name policy = do
  _ ← evaluate (operationText name)
  disposition ← evaluate (policyDisposition policy)
  budget ← evaluate (policyBudget policy)
  classifier ← evaluate (policyClassifier policy)
  wait ← evaluate (policyWait policy)
  when (budget < 1) $ throwIO (NonPositiveBudget budget)
  pure (ValidatedPolicy disposition budget classifier wait)

-- | Construct a live component for the rest of the enclosing scope, selecting
-- among 'Assembly' alternatives under a recovery policy.
--
-- The policy is 'recover'\'s, read the same way: the caller supplies it for the
-- named component, the component supplies its classifier, one budget counts
-- the initial attempt and every later one, and the caller's 'Disposition'
-- decides whether exhaustion propagates or binds 'Unavailable'. 'Retry' runs
-- the initial assembly again, even after a fallback. @'Fallback' name select@
-- names an alternative: @select@ runs as the first step of that attempt, with
-- the caller's masking state restored and nothing acquired yet, and the
-- assembly it returns is the rest of the attempt, so a failure of @select@ is
-- that attempt's failure. The policy is validated when the scope is entered,
-- before any alternative runs; an invalid budget throws
-- 'InvalidRecoveryPolicy' and causes no effect.
--
-- Each attempt, in order:
--
-- 1. Runs its assembly against a fresh part ledger, under the rules of
--    'Hetoimasia.Foundation.Resource.withComposite': acquisition and rollback
--    installation are one protected step, part metadata is evaluated before
--    its acquisition, and 'Hetoimasia.Foundation.Resource.restoredStep' is the
--    only restored work.
-- 2. On failure, releases exactly the parts that attempt acquired, in their
--    declared order, before anything else looks at the failure. The
--    construction failure stays primary with every cleanup failure retained.
-- 3. A cancellation that failed the attempt propagates with that rollback
--    evidence. A cancellation requested while the rollback ran is deferred
--    until every release has been attempted, then delivered with the caller's
--    masking state restored; it propagates with the rollback's cleanup
--    evidence retained and the construction failure attached as
--    'WhileHandling'. A caller that is already masked keeps its state, and
--    the request stays pending.
-- 4. A failure carrying cleanup evidence propagates: an attempted release is
--    not proof of disposal, so no other alternative runs.
-- 5. The classifier is consulted, then the budget, then the disposition, and
--    the wait runs before a later attempt, exactly as in 'recover' — the
--    classifier and the wait with the caller's masking state, since nothing is
--    held while they run. A failure raised by either stops construction with
--    the handled failure attached as 'WhileHandling'; a cancellation there
--    propagates as itself. An exhausted 'Required' construction, or one stopped
--    by an unrecognized failure or failed cleanup, propagates its latest
--    failure with one 'RecoveryHistory' of the earlier attempts.
--
-- A successful attempt's ledger becomes the scope's release without leaving
-- the masked region: the continuation's failure handler is installed while
-- still masked, and only then is the caller's masking state restored and the
-- continuation invoked with 'Available', carrying the handle, the attempt kind
-- that built it, and every earlier failed attempt. There is no interval in
-- which the handle lacks its release, and no token exposing that release. A
-- cancellation delivered at that handoff may preempt the continuation's first
-- effect; it still releases every acquired part and propagates with the
-- evidence of that release.
--
-- Exhausted 'Optional' construction invokes the continuation with
-- 'Unavailable' after its rollback has finished. It holds no handle and runs
-- no further release.
--
-- Once construction resolves, the continuation runs at most once — exactly
-- once unless a cancellation preempts it — and nothing after that point can
-- start another attempt. Its failure, a lazy value it forces, and a failure of
-- the final release follow the failure table of
-- 'Hetoimasia.Foundation.Resource.withResource': a continuation failure
-- propagates with cleanup evidence retained, and a release failure after a
-- successful continuation is primary with the result discarded. Construction
-- that propagates never invokes the continuation.
--
-- The handle is borrowed. It is valid only inside the enclosing
-- 'Hetoimasia.Foundation.Resource.withScoped' continuation, whose result must
-- be an ordinary, fully evaluated value.
--
-- The state this constructor holds is private to one entry into the scope:
--
-- * each attempt's part ledger, written by that attempt's assembly and read by
--   its rollback, on the entering thread, from the attempt's start until its
--   rollback empties it or, for the selected attempt, until the scope's release
--   empties it; it is never reused;
-- * the selected release, which is that ledger, held by the scope and run
--   exactly once when the continuation returns or throws;
-- * the attempt history, an immutable list built on the entering thread,
--   oldest first and bounded by the budget, handed to the continuation or to
--   the propagated failure and never mutated or reset.
allocComponent ∷ Operation → RecoveryPolicy (Assembly a) → Assembly a → Scoped (Outcome a)
allocComponent name policy initial = Scoped $ \continue → do
  ValidatedPolicy disposition budget classifier wait ← validatePolicy name policy
  mask $ \restore → do
    let attempt number kind construction earlier = do
          built ← assemble restore construction
          case built of
            Right (ledger, value) →
              lendAssembled restore ledger (Available (Recovered value kind (reverse earlier))) continue
            Left failed@(ExceptionWithContext context exception)
              | isCancellation exception → rethrowIO failed
              | otherwise → do
                  deliverPendingCancellation restore failed
                  if not (null (cleanupFailuresInContext context))
                    then rethrowIO handled
                    else do
                      selected ← guarded handled (restore (classifier failure >>= evaluateStrategy))
                      case selected of
                        Nothing → rethrowIO handled
                        Just strategy
                          | number >= budget → case disposition of
                              Required → rethrowIO handled
                              Optional →
                                restore (continue (Unavailable (Unavailability name failure (reverse earlier))))
                          | otherwise → do
                              guarded handled (restore (wait (number + 1)))
                              case strategy of
                                Retry →
                                  attempt (number + 1) RetryAttempt initial (failure : earlier)
                                Fallback fallbackName select →
                                  attempt
                                    (number + 1)
                                    (FallbackAttempt fallbackName)
                                    (join (restoredStep select))
                                    (failure : earlier)
              where
                failure = AttemptFailure number kind failed
                handled = withHistory name earlier failed
    attempt 1 InitialAttempt initial []

-- | Give a cancellation requested during a rollback its delivery point, now
-- that every release has been attempted, and attach what the rollback left.
--
-- Nothing is held here, so restoring the caller's masking state is safe. A
-- caller that was already masked stays masked and the request stays pending.
deliverPendingCancellation
  ∷ (∀ x. IO x → IO x)
  → ExceptionWithContext SomeException
  → IO ()
deliverPendingCancellation restore failed@(ExceptionWithContext failedContext _) = do
  delivered ← tryWithContext (restore (pure ()))
  case delivered of
    Right () → pure ()
    Left (ExceptionWithContext context cancellation) →
      rethrowIO
        ( retainCleanupFailures
            (cleanupFailuresInContext failedContext)
            ( ExceptionWithContext
                (addExceptionAnnotation (WhileHandling (toException failed)) context)
                (cancellation ∷ SomeException)
            )
        )

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
