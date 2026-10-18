-- | Retained retirement: an obligation a provider has yet to complete, kept charged to
-- whatever it was recorded against until the provider proves it over, with the disposals of
-- what it needs held behind it.
--
-- This is the one primitive that instance leases (#473) and asynchronous requests (LUA-7)
-- share. A lease records one for each resource whose provider retires it later; a request
-- records one for the provider work it handed out. Neither keeps a copy of the rules, which
-- are:
--
-- * a provider's reading is application code. It is run in a transaction that must not
--   retry, and what it throws, when it runs or when what it answered is first inspected, is
--   the retirement failing, not an exception loose in whatever polls it ('pollObligation');
-- * a retirement that completes gives its charge back; one that fails is retained as
--   evidence by whoever owns it, and nothing is retried or reported as reclaimed;
-- * the disposal of what a retirement needs is held behind every obligation recorded, run
--   once they have all completed, and never if one failed or the owner has a failure
--   already ('sweep'). Running it is the owner's: uninterruptibly, on its own thread;
-- * every call into provider or application code on the owner's behalf goes through one
--   guard, 'guarded', and is evaluated inside it, so a failure is evidence and not a reason
--   to stop serving the others.
--
-- This is a hidden module of the adapter.
module Hetoimasia.Scripting.Lua.Retention
  ( -- * What a provider says
    RetirementState (..)
  , Obligation (..)
  , pollObligation
  , guarded

    -- * What is retained
  , Retained (..)
  , noRetained
  , retain
  , retainedPending
  , defer
  , Ended (..)
  , sweep
  , pollAll
  ) where

import Control.Concurrent.STM (STM, catchSTM, orElse)
import Control.Exception
  ( ExceptionWithContext (ExceptionWithContext)
  , SomeException
  , evaluate
  , someExceptionContext
  , tryWithContext
  )
import Control.Monad (forM)
import Data.Text (Text)

-- | Where a provider's retirement of a resource has got to.
data RetirementState
  = -- | The provider has not finished.
    ProviderPending
  | -- | The provider has proved the resource retired.
    ProviderComplete
  | -- | The provider could not retire it. The failure is cleanup evidence.
    ProviderFailed !SomeException

-- | A retirement a provider has yet to complete, charged to whatever recorded it.
data Obligation = Obligation
  { obligationLabel ∷ !Text
  , obligationState ∷ STM RetirementState
    -- ^ The provider's own reading. It must not retry.
  }

-- | Ask a provider where its retirement has got to, as a retirement and nothing else can
-- fail it. The provider's reading is application code and may throw, when it is run or
-- when what it answered is evaluated: either is the retirement failing, and is how it is
-- retained, as cleanup evidence, while the others go on being served and awaited. The
-- reading is evaluated, as far as anything later inspects it, inside the guard that
-- catches what it throws. A reading that retries says it is not done.
--
-- This is the one place a provider's reading is run: servicing and the wait for readiness
-- both read through it.
pollObligation ∷ Obligation → STM RetirementState
pollObligation obligation =
  (reading `catchSTM` \failure → pure (ProviderFailed (failure ∷ SomeException)))
    `orElse` pure ProviderPending
  where
    reading = obligationState obligation >>= evaluated
    -- The constructor is evaluated here, with the failure it carries (a strict field): all
    -- that servicing and readiness go on to inspect.
    evaluated state = case state of
      ProviderPending → pure state
      ProviderComplete → pure state
      ProviderFailed failure → failure `seq` pure state

-- | Run a call into provider or application code during retirement or teardown, answering
-- the failure it raised, with its context, instead of raising it, and evaluating what it
-- answered inside the same guard: a value that throws when it is first inspected is the
-- call failing, not an exception loose in whatever inspects it. Every such call that is
-- run on the owner's behalf goes through here, so that a failure is evidence and not a
-- reason to stop serving the others.
guarded ∷ IO a → IO (Either (ExceptionWithContext SomeException) a)
guarded action = tryWithContext @SomeException (action >>= evaluate)

-- | What one owner of retirements holds: the obligations still pending, and the disposals
-- held behind them.
data Retained = Retained
  { retainedObligations ∷ ![Obligation]
  , retainedDeferred ∷ ![IO ()]
    -- ^ Disposals of what the pending retirements need: run, in order, once every one of
    -- them has completed, and never if one fails.
  }

-- | Nothing pending and nothing held.
noRetained ∷ Retained
noRetained = Retained [] []

-- | Record an obligation.
retain ∷ Obligation → Retained → Retained
retain obligation held = held {retainedObligations = retainedObligations held <> [obligation]}

-- | Whether any obligation is pending.
retainedPending ∷ Retained → Bool
retainedPending = not . null . retainedObligations

-- | Hand a disposal to the pending obligations: it is kept until every one of them has
-- completed. With none pending there is nothing to wait for, and the disposal is handed
-- back to be run now.
defer ∷ IO () → Retained → (Retained, Maybe (IO ()))
defer disposal held
  | retainedPending held = (held {retainedDeferred = retainedDeferred held <> [disposal]}, Nothing)
  | otherwise = (held, Just disposal)

-- | A retirement that came to an end: its label, and the failure if it failed.
data Ended = Ended
  { finishedLabel ∷ !Text
  , finishedFailure ∷ !(Maybe (ExceptionWithContext SomeException))
  }

-- | Read every obligation and take away the ones the providers have finished. Answers what
-- is left and what ended. Never waits: a reading is a transaction that must not retry.
pollAll ∷ [Obligation] → STM ([Obligation], [Ended])
pollAll obligations = do
  polled ← forM obligations $ \obligation → do
    reading ← pollObligation obligation
    pure $ case reading of
      ProviderPending → Left obligation
      ProviderComplete → Right (Ended (obligationLabel obligation) Nothing)
      ProviderFailed failure → Right (Ended (obligationLabel obligation) (Just (ExceptionWithContext (someExceptionContext failure) failure)))
  pure ([obligation | Left obligation ← polled], [ended | Right ended ← polled])

-- | Read what is retained, as 'pollAll' does, and answer the disposals that are now due:
-- those held behind obligations that have all completed without failure. They are answered
-- once and forgotten here; running them is the caller's. A disposal is never due when an
-- obligation failed, or when the caller says it is @blocked@ (it already holds a failure
-- of its own).
sweep ∷ Bool → Retained → STM (Retained, [Ended], [IO ()])
sweep blocked held = do
  (remaining, ended) ← pollAll (retainedObligations held)
  let failed = [failure | Ended _ (Just failure) ← ended]
      disposing = null remaining && null failed && not blocked && not (null (retainedDeferred held))
  pure
    ( Retained remaining (if disposing then [] else retainedDeferred held)
    , ended
    , if disposing then retainedDeferred held else []
    )
