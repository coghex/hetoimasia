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
--   the retirement failing, not an exception loose in whatever polls it ('pollObligation').
--   It is a /reading/: it asks where the provider's work has got to, and what it writes is not
--   kept. The engine may poll it inside a transaction that has already read, and so may be
--   asked to run it against a view another thread has since committed over; running it is
--   what notices, and the poll then starts again from a consistent view instead of running the
--   reading again against the stale one (see 'pollObligation');
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

import Control.Concurrent.STM (STM, catchSTM, orElse, throwSTM)
import Control.Exception
  ( Exception
  , ExceptionWithContext (ExceptionWithContext)
  , SomeException
  , evaluate
  , fromException
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
    -- ^ The provider's own reading. It must not retry, and it only reads: what it writes is
    -- not kept (see 'pollObligation').
  }

-- | Ask a provider where its retirement has got to, as a retirement and nothing else can
-- fail it. The provider's reading is application code and may throw, when it is run or
-- when what it answered is evaluated: either is the retirement failing, and is how it is
-- retained, as cleanup evidence, while the others go on being served and awaited. The
-- reading is evaluated, as far as anything later inspects it, inside the guard that
-- catches what it throws. A reading that retries says it is not done.
--
-- This is the one place a provider's reading is run: servicing, the wait for readiness and
-- the request and subscription services all read through it.
--
-- = A reading is never run again against a stale view
--
-- The engine polls readings inside a transaction that has usually read state already, and
-- several readings in one transaction may read one TVar. A reading runs in a nested
-- transaction, and a nested transaction that finds the TVars it read changed by another thread
-- is run again at once, still under the enclosing transaction's copy of what that thread
-- overwrote: it reads the same stale value, fails the same way, and does not return to the
-- scheduler to be restarted whole, for as long as it does not happen to allocate.
--
-- So a reading never leaves its nested transaction by returning. It leaves by raising its
-- answer (a private exception, caught here), and GHC does not handle an exception raised in
-- a transaction that is no longer valid: it restarts the transaction from the beginning,
-- with a view that is consistent, before any handler runs. The poll therefore sees its
-- reading's answer only if what the reading read was current, and a conflicting commit costs
-- one more run of the reading, whatever the reading does or does not allocate. This holds by
-- the semantics of the transaction, not by a build or runtime setting.
--
-- The price is that a reading's own writes are rolled back with the exception. A reading
-- reads: it must not retry, and it must not write anything it needs kept.
pollObligation ∷ Obligation → STM RetirementState
pollObligation obligation =
  ((reading >>= throwSTM . Polled) `catchSTM` outcome)
    `orElse` pure ProviderPending
  where
    reading = obligationState obligation >>= evaluated
    outcome failure = case fromException failure of
      Just (Polled state) → pure state
      Nothing → pure (ProviderFailed failure)
    -- The constructor is evaluated here, with the failure it carries (a strict field): all
    -- that servicing and readiness go on to inspect.
    evaluated state = case state of
      ProviderPending → pure state
      ProviderComplete → pure state
      ProviderFailed failure → failure `seq` pure state

-- | What a reading answered, raised out of its nested transaction so that GHC validates the
-- transaction before it is read. Private to 'pollObligation': nothing else can raise it, so
-- nothing a provider throws is taken for an answer.
newtype Polled = Polled RetirementState

instance Show Polled where
  show _ = "Polled"

instance Exception Polled

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
