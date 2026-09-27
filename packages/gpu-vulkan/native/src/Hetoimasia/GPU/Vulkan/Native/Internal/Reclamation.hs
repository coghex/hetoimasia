-- | Allocation recovery (VK-14, D-25): one bounded reclamation pass over
-- backend-owned subjects already eligible for disposal, and at most one retry
-- of the operation that failed, only once that pass actually disposed of
-- something.
--
-- It is entered only for a native allocation failure whose operation's
-- contract says it had no effect — an out-of-memory submission or
-- presentation — or for a construction whose rollback is proven complete,
-- such as a creation call that raised and so created nothing. The caller
-- decides which it has; this module never generalizes a no-effect guarantee
-- to anything else, and configured-capacity exhaustion, which is
-- backpressure, never reaches it.
--
-- = The pass
--
-- The model decides the pass: 'reclaimPass' reads a bounded window of
-- generation and managed-resource records — ineligible ones count against the
-- window too — from a cursor it carries from pass to pass. Which subjects the
-- window offers is read by running that same pass on a copy of the model whose
-- every offered disposal succeeds, which changes nothing; exactly those
-- subjects are then offered to the layers that own them, each of which
-- destroys its own natively, on the owner's thread, with the destruction and
-- its record in one masked step ('SubjectDisposer'). A subject no layer can
-- destroy now — a pipeline layout a live pipeline still uses, a generation
-- already destroyed and awaiting its record — is refused, which the model
-- counts as nothing. Only then does the real pass run, told what each
-- destruction did. Nothing waits for unfinished work, and nothing but a
-- destruction that returned is progress.
--
-- = The retry
--
-- The model's allocation attempt carries the one retry: 'retryAllocation'
-- permits it only after a pass confirmed a successful disposal since the
-- failure, never after the attempt's construction retired a generation as
-- @oldSwapchain@, and never in a failed session — so a disposal that failed,
-- which escalates the session, forbids it however much else the pass
-- reclaimed. A retry that fails again ends the recovery. Either way the
-- original failure is reported, with what the pass examined, disposed of and
-- failed to dispose of ('AllocationNotRecovered').
--
-- This module owns no state. It reads the roots' model and the disposers each
-- layer registered with the roots, and advances the model.
module Hetoimasia.GPU.Vulkan.Native.Internal.Reclamation
  ( -- * The pass
    reclaimOnce

    -- * Recovering one failed allocation
  , RecoveryEnd (..)
  , AllocationNotRecovered (..)
  , recoverAllocation
  , failingAgain
  , withAllocationAttempt
  , recoveringCreation
  ) where

import Control.Concurrent.STM (atomically)
import Control.Exception
  ( Exception (displayException)
  , ExceptionWithContext (ExceptionWithContext)
  , SomeAsyncException
  , SomeException
  , fromException
  , mask
  , rethrowIO
  , throwIO
  , tryWithContext
  )
import Control.Monad (forM, unless)
import Data.Foldable (for_)
import Data.Maybe (isJust)
import Data.Text (Text)
import qualified Data.Text as Text
import Numeric.Natural (Natural)

import Hetoimasia.GPU.Model
  ( DisposalResult (..)
  , EvidenceSource (..)
  , Outcome (..)
  , ReclaimReport (..)
  , RetryVerdict (..)
  , SessionFailureCause (CleanupFailed)
  , abandonAllocation
  , beginAllocation
  , noteOldSwapchainRetired
  , reclaimPass
  , recordAllocationFailure
  , retryAllocation
  , silentEvidence
  )
import Hetoimasia.GPU.Model.Identity (AllocationId, GenerationId, HoldSubject)
import Hetoimasia.GPU.Vulkan.Native.Roots
  ( GraphicsDeviceLost
  , NativeFailure (FailedOutOfMemory)
  , Roots
  , SubjectDisposer (..)
  , failRootsSession
  , readRootsDisposers
  , rootsNativeFailure
  , stateRootsModel
  )

-- | Run one reclamation pass: offer the subjects the model's next bounded
-- window holds eligible to the layers that own them, and record what each
-- destruction did. A disposal that failed is retained, never offered again,
-- and fails the session with 'CleanupFailed'.
reclaimOnce ∷ Roots q inst msgr phys dev → IO ReclaimReport
reclaimOnce roots = do
  (offered, disposers) ← atomically $ do
    model ← stateRootsModel roots (\model → (model, model))
    -- The same pass, on a copy whose every disposal succeeds, answers exactly
    -- the eligible subjects of the window the real pass will read.
    let (_, window) = reclaimPass silentEvidence {disposalEvidence = const DisposalCompleted} model
    (,) (reclaimDisposed window) <$> readRootsDisposers roots
  results ← forM offered $ \subject → (,) subject <$> disposeWith disposers subject
  atomically $ do
    report ← stateRootsModel roots $ \model →
      let (next, answered) = reclaimPass silentEvidence {disposalEvidence = evidenceFrom results} model
       in (answered, next)
    for_ disposers (\disposer → disposerForget disposer (reclaimDisposed report))
    unless (null (reclaimFailures report)) (failRootsSession roots CleanupFailed)
    pure report
  where
    evidenceFrom results subject = maybe DisposalRefused id (lookup subject results >>= id)
    disposeWith [] _ = pure Nothing
    disposeWith (disposer : rest) subject =
      disposerDispose disposer subject >>= \case
        Nothing → disposeWith rest subject
        answered → pure answered

-- | How an allocation recovery ended without the retry succeeding.
data RecoveryEnd
  = RetryRefused !RetryVerdict
    -- ^ The model refused the retry: nothing was reclaimed, the retry was
    -- already spent, or the attempt retired a generation as @oldSwapchain@.
  | RetryUnadmitted !Text
    -- ^ No retry could be admitted at all: the session has failed, or no
    -- attempt could be accounted for.
  | RetryFailedAgain !Text
    -- ^ The one retry was made and failed too, with this.
  deriving (Eq, Show)

-- | An allocation failure recovery did not overcome. It reports the original
-- failure, and the evidence of the recovery: what the reclamation pass
-- examined, what it disposed of and what it failed to dispose of, and how the
-- recovery ended.
data AllocationNotRecovered = AllocationNotRecovered
  { notRecoveredOperation ∷ !Text
  , notRecoveredFailure ∷ !Text
    -- ^ The original failure, as it displayed.
  , notRecoveredExamined ∷ !Natural
  , notRecoveredDisposed ∷ ![HoldSubject]
  , notRecoveredFailed ∷ ![HoldSubject]
  , notRecoveredEnd ∷ !RecoveryEnd
  }
  deriving (Eq, Show)

instance Exception AllocationNotRecovered where
  displayException failure =
    Text.unpack (notRecoveredOperation failure)
      <> " failed and was not recovered: "
      <> Text.unpack (notRecoveredFailure failure)
      <> " (reclamation examined "
      <> show (notRecoveredExamined failure)
      <> " records, disposed of "
      <> show (length (notRecoveredDisposed failure))
      <> ", failed to dispose of "
      <> show (length (notRecoveredFailed failure))
      <> "; "
      <> show (notRecoveredEnd failure)
      <> ")"

-- | Recover one failed allocation, whose attempt the caller holds, given the
-- operation's name and what its failure displayed: record the
-- failure, note a generation its construction already retired as
-- @oldSwapchain@, run one reclamation pass, and run the failed operation once
-- more only if the model permits the attempt's one retry.
--
-- The retry answers 'Left' with what it displayed when it failed again in the
-- way the operation recognizes — see 'failingAgain' — and anything it raises
-- is re-raised unchanged: device loss stays primary, an unknown effect stays
-- the session's, and a cancellation is never a failed retry.
--
-- Answers the retry's result, or the recovery's report of why there was none
-- or it failed too. The attempt stays the caller's, to abandon or to consume.
recoverAllocation
  ∷ Roots q inst msgr phys dev
  → Text
  → AllocationId
  → Maybe GenerationId
  → Text
  → IO (Either Text a)
  → IO (Either AllocationNotRecovered a)
recoverAllocation roots operation attempt retired original retry = do
  atomically $ do
    edit (recordAllocationFailure attempt)
    for_ retired (edit . noteOldSwapchainRetired attempt)
  report ← reclaimOnce roots
  verdict ← atomically $ stateRootsModel roots $ \model → case retryAllocation attempt model of
    Admitted (next, answer) → (Right answer, next)
    Rejected misuse → (Left (Text.pack (show misuse)), model)
    Backpressure kind → (Left (Text.pack (show kind)), model)
  let notRecovered = Left . AllocationNotRecovered operation original (reclaimExamined report) (reclaimDisposed report) (reclaimFailures report)
  case verdict of
    Left why → pure (notRecovered (RetryUnadmitted why))
    Right RetryPermitted →
      retry >>= \case
        Right value → pure (Right value)
        Left again → pure (notRecovered (RetryFailedAgain again))
    Right refused → pure (notRecovered (RetryRefused refused))
  where
    edit operation' = stateRootsModel roots $ \model → case operation' model of
      Admitted next → ((), next)
      _ → ((), model)

-- | A construction's retry: any synchronous failure it raises ends the
-- recovery, with what it displayed — a second failure is never retried — but
-- device loss and a cancellation are re-raised, since neither is a failed
-- retry.
failingAgain ∷ IO a → IO (Either Text a)
failingAgain retry =
  tryWithContext retry >>= \case
    Right value → pure (Right value)
    Left failure@(ExceptionWithContext _ exception)
      | isAsynchronous exception || isJust (fromException exception ∷ Maybe GraphicsDeviceLost) → rethrowIO failure
      | otherwise → pure (Left (Text.pack (displayException exception)))

-- | Account one allocation attempt for an operation that reserves none of its
-- own — a swapchain or view creation, a submission, a presentation — for as
-- long as its recovery runs, and give the accounting back however it ends. An
-- attempt that cannot be accounted for — the session has failed, or the
-- object budget is exhausted, which is backpressure — is 'Left', and there is
-- no recovery.
withAllocationAttempt ∷ Roots q inst msgr phys dev → (AllocationId → IO a) → IO (Either Text a)
withAllocationAttempt roots use = mask $ \restore → do
  begun ← atomically $ stateRootsModel roots $ \model → case beginAllocation 0 1 model of
    Admitted (next, attempt) → (Right attempt, next)
    Rejected misuse → (Left (Text.pack (show misuse)), model)
    Backpressure kind → (Left (Text.pack (show kind)), model)
  case begun of
    Left why → pure (Left why)
    Right attempt → do
      answered ← tryWithContext (restore (use attempt))
      atomically $ stateRootsModel roots $ \model → case abandonAllocation attempt model of
        Admitted next → ((), next)
        _ → ((), model)
      either (\(failure ∷ ExceptionWithContext SomeException) → rethrowIO failure) (pure . Right) answered

-- | Run one native creation call, recovering an out-of-memory failure. A
-- creation call that raised created nothing, which is the proven rollback
-- allocation recovery needs: one reclamation pass, and the call once more only
-- if the model permits the attempt's retry — never when the call handed the
-- given generation over as @oldSwapchain@, which it retired whatever it
-- answered. Anything else it raised, and a recovery that did not succeed, is
-- raised: the original failure as itself when no attempt could even be
-- accounted for, and 'AllocationNotRecovered' otherwise.
recoveringCreation ∷ Roots q inst msgr phys dev → Text → Maybe GenerationId → IO a → IO a
recoveringCreation roots name retired call =
  tryWithContext call >>= \case
    Right value → pure value
    Left failure@(ExceptionWithContext _ exception)
      | not (isAsynchronous exception)
      , rootsNativeFailure roots exception == Just FailedOutOfMemory →
          withAllocationAttempt roots (\attempt → recoverAllocation roots name attempt retired (Text.pack (displayException exception)) (failingAgain call)) >>= \case
            Right (Right value) → pure value
            Right (Left notRecovered) → throwIO notRecovered
            Left _ → rethrowIO failure
      | otherwise → rethrowIO failure

isAsynchronous ∷ SomeException → Bool
isAsynchronous exception = isJust (fromException exception ∷ Maybe SomeAsyncException)
