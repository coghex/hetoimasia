-- | What a worker and its group leave behind: the run-exit record, the terminal
-- result and completion, the startup report, the group report, and the shared
-- helpers that classify a caught failure and read its cleanup evidence.
--
-- This module belongs to the package's private @internal@ sublibrary and is
-- not exposed even there: "Hetoimasia.Foundation.Worker.Internal" re-exports
-- the outcome types for the rest of the package, and the other worker modules
-- import this module directly. It is private because the classification
-- helpers here — 'trySome', 'failureResult', 'resultCleanup', and 'succeeded'
-- — are the implementation's own and are not part of the public contract.
--
-- It imports only "Hetoimasia.Foundation.Worker.Base" and the resource
-- family's "Hetoimasia.Foundation.Resource.Cleanup": an outcome is data about a
-- worker, never worker state, so the modules that own state can import it
-- without a cycle. It holds no state.
module Hetoimasia.Foundation.Worker.Outcome
  ( -- * Outcomes
    RunEnd (..)
  , RunExit (..)
  , Result (..)
  , Completion (..)
  , WorkerSummary
  , Startup (..)
  , StartRejection (..)
  , GroupReport (..)
  , reportCleanup

    -- * Shared helpers
  , trySome
  , failureResult
  , resultCleanup
  , succeeded
  ) where

import Control.Exception
  ( ExceptionWithContext (ExceptionWithContext)
  , SomeAsyncException
  , SomeException
  , fromException
  , tryWithContext
  )
import Data.Maybe (isJust)
import Data.Text (Text)
import Hetoimasia.Foundation.Resource.Cleanup (CleanupFailure, cleanupFailuresInContext)
import Hetoimasia.Foundation.Worker.Base (Requested, WorkerId)

-- Outcomes -------------------------------------------------------------------

-- | How the run action itself ended.
data RunEnd
  = RunReturned
  | RunFailed
    -- ^ The run action raised a synchronous exception.
  | RunCancelled
    -- ^ The run action was ended by an asynchronous exception.
  deriving (Eq, Show)

-- | The record the worker writes when its run action exits, before any of its
-- own cleanup begins.
data RunExit
  = RunNotEntered
    -- ^ The run action never started: startup failed or was cancelled, the
    -- start handoff was abandoned, or the fork itself failed.
  | RunExited !RunEnd !Requested
    -- ^ The run action ended this way, and this was the strongest request
    -- already made when it did. The record is written in the same transaction
    -- that reads the requests, so a request arriving during cleanup cannot
    -- change it.
  deriving (Eq, Show)

-- | The terminal result of one worker, published after its scopes unwound.
data Result r
  = Succeeded r
    -- ^ The run action returned this value, evaluated to weak head normal
    -- form inside the worker's scope, and every release succeeded.
  | Failed !(ExceptionWithContext SomeException)
    -- ^ A synchronous failure of startup, the run action, or a release, with
    -- its own context: its origin and cleanup evidence stay inspectable.
  | Cancelled !(ExceptionWithContext SomeException)
    -- ^ An asynchronous exception ended the worker, with its own context.
  deriving (Show, Functor)

-- | One worker's terminal outcome.
--
-- It is published exactly once, after the worker's startup scope and every
-- allocation in it have unwound, and it never changes. After it is published
-- no worker code or finalizer of that worker touches a borrowed dependency.
data Completion r = Completion
  { completionWorker ∷ !WorkerId
  , completionLabel ∷ !Text
  , completionExit ∷ !RunExit
  , completionResult ∷ !(Result r)
  , completionCleanup ∷ ![CleanupFailure]
    -- ^ The cleanup failures the terminal failure retained, in observation
    -- order; empty for a success.
  }
  deriving (Functor)

-- | A 'Completion' with its result value discarded, as a group retains it.
type WorkerSummary = Completion ()

-- | What 'Hetoimasia.Foundation.Worker.awaitStartup' reports.
data Startup r
  = Acknowledged
    -- ^ Startup succeeded and the worker's resources are live for its run.
    -- The worker may also have completed since; check
    -- 'Hetoimasia.Foundation.Worker.pollCompletion'.
  | NotAcknowledged !(Completion r)
    -- ^ The worker ended before acknowledging. Its 'completionExit' is
    -- 'RunNotEntered', and its cleanup has finished.

-- | Why a start forked nothing.
data StartRejection = RegistrationClosed
  deriving (Eq, Show)

-- | What a group reports once it has closed and drained.
--
-- Every list is in registration order.
data GroupReport = GroupReport
  { reportExitedBeforeClosing ∷ ![WorkerSummary]
    -- ^ Workers whose terminal outcome was published but not observed with
    -- 'Hetoimasia.Foundation.Worker.observeCompletion' when closing began.
    -- None of them was asked to stop by closing.
  , reportDrained ∷ ![WorkerSummary]
    -- ^ Workers still live when closing began, after the drain. Their
    -- 'RunExit' says whether each run action ended before closing's request.
  , reportObservedFailures ∷ ![WorkerSummary]
    -- ^ Outcomes other than 'Succeeded' that an owner had already observed
    -- before closing began, including retired ones.
  }

-- | Every cleanup failure the report's workers retained: observed failures
-- first, then workers that exited before closing, then drained workers.
reportCleanup ∷ GroupReport → [CleanupFailure]
reportCleanup report =
  concatMap completionCleanup $
    reportObservedFailures report <> reportExitedBeforeClosing report <> reportDrained report

-- Shared helpers -------------------------------------------------------------

-- | Catch anything, including a cancellation, with the context it carried.
trySome ∷ IO a → IO (Either (ExceptionWithContext SomeException) a)
trySome = tryWithContext

-- | Classify a caught failure: an asynchronous exception is a cancellation,
-- anything else a failure.
failureResult ∷ ExceptionWithContext SomeException → Result r
failureResult caught@(ExceptionWithContext _ exception)
  | isJust (fromException exception ∷ Maybe SomeAsyncException) = Cancelled caught
  | otherwise = Failed caught

-- | The cleanup failures a terminal result retained on its context.
resultCleanup ∷ Result r → [CleanupFailure]
resultCleanup (Succeeded _) = []
resultCleanup (Failed (ExceptionWithContext context _)) = cleanupFailuresInContext context
resultCleanup (Cancelled (ExceptionWithContext context _)) = cleanupFailuresInContext context

-- | Whether a completion is a success.
succeeded ∷ Completion r → Bool
succeeded completion = case completionResult completion of
  Succeeded _ → True
  _ → False
