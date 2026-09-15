-- | The generic application lifecycle.
--
-- 'runScopedApplication' and 'runScopedApplicationWithQuiescence' sit beside
-- 'Hetoimasia.Runtime.runApplication', the thin runner over a supplied logger,
-- which keeps its module, signature, behavior, and examples. They compose the
-- runtime's other boundaries in one fixed order and add no mechanics of their
-- own:
--
-- 1. Configuration parsing and logger construction happen before it, in the
--    caller. A failure there propagates as its own typed failure, with no
--    record promised, because no managed logger exists yet.
-- 2. The logging lifetime is entered ("Hetoimasia.Runtime.Logging").
-- 3. The application's dependencies are constructed inside it, as one 'Scoped'
--    value run by 'withScoped', in the order the composition allocates them.
--    A required component built with
--    'Hetoimasia.Foundation.Recovery.allocComponent' propagates its failure
--    after cleanup of what was acquired; an optional one binds its
--    availability value only after safe rollback. A construction failure
--    disposes what was acquired without entering the worker group.
-- 4. A supervised worker group is entered inside those scopes
--    ("Hetoimasia.Runtime.Supervision"), and the application quiescence guard
--    is installed immediately inside it, before the first checkpoint.
-- 5. The startup callback runs on the calling thread with the dependencies and
--    the 'RuntimeControl'. It may start and acknowledge workers, and it returns
--    the application's immutable services value.
-- 6. A checkpoint runs before that value is handed over.
-- 7. The action runs on the calling thread with the services value and the
--    control, and a checkpoint runs before its result is accepted.
-- 8. The quiescence action runs once, with the dependencies still live, as the
--    guard's release. 'runScopedApplication' supplies one that does nothing.
-- 9. Supervision closes: registration closes, every live worker is asked to
--    stop, every worker is drained, and every outcome not yet handled is
--    settled, with the fatal latch rethrown.
-- 10. The dependency scope unwinds: dependents are disposed before their
--     dependencies, and each composite keeps its declared internal order.
-- 11. A failed run gets one managed terminal report while the logger is live.
-- 12. The logging lifetime makes its one permitted final flush.
-- 13. The result is returned, or the failure is rethrown preservingly.
--
-- Steps 9 to 13 happen on every exit path: construction failure (from step
-- 10), startup failure, action failure, a supervisor-detected failure, and
-- owner cancellation, which skips steps 11 and 12. Step 8 happens on every
-- exit once the guard is installed — a checkpoint failure, startup or action
-- failure, action cancellation, and a successful return — and never after a
-- construction failure, when no worker group was entered.
--
-- __Quiescence.__ Dependencies are services the workers may wait on, such as
-- a component whose command port is executed by the calling thread. Once the
-- action returns, nothing executes those commands, so a worker still awaiting
-- a reply could not finish stopping and the drain in step 9 would wait on it.
-- The quiescence action closes that gap: it is the application's
-- dependency-local transaction, of shape @dependencies → STM ()@, that closes
-- admission and settles pending requests — refusing a reply a worker awaits,
-- for instance — so that worker can observe its stop request and exit.
--
-- It runs as the release of a guard entered through
-- 'Hetoimasia.Foundation.Resource.withResourceLabelled' under the label
-- @application quiescence@, so it runs under @uninterruptibleMask_@, exactly
-- once, with the dependencies live and before supervision begins its boundary
-- close: registration closure, stop requests to remaining workers, and the
-- boundary drain. That is the whole ordering promise. It does not precede:
--
-- * the stop requests the fatal latch makes. Settling a fatal worker outcome
--   latches it and asks every pending worker to stop in the same transaction,
--   before 'checkRuntime' or 'Hetoimasia.Runtime.Supervision.awaitSupervised'
--   rethrows it and the guard runs;
-- * the drain of an individual worker whose managed startup was abandoned.
--   When 'Hetoimasia.Runtime.Supervision.startSupervised' fails or is
--   cancelled while preparing or waiting for startup, that worker is cancelled
--   and drained before the failure propagates to the guard.
--
-- A worker finalizer therefore cannot depend on a calling-thread command after
-- quiescence, nor, in those two cases, on one issued before it.
--
-- The action is finite, non-retrying component bookkeeping. It receives the
-- dependencies and nothing else; it destroys nothing, waits for no worker,
-- executes no queued work, pumps no native event, flushes no log, and invokes
-- no application callback. Because it runs uninterruptibly, a transaction that
-- retries blocks the calling thread with the drain never reached: that is an
-- implementation defect of the action, not a waiting strategy, and the runtime
-- does not try to make arbitrary STM non-retrying.
--
-- Its failure follows the resource failure table. If startup, the action, a
-- checkpoint, or cancellation already failed the run, that failure propagates
-- with its type, value, and context, and the quiescence failure is retained
-- beside it as @application quiescence@ cleanup evidence. If the work
-- succeeded, its result is discarded and the quiescence failure becomes
-- primary, retained under the same label; supervision then closes as it does
-- for any body failure, the dependencies unwind, and the run is reported and
-- flushed as a failure under the outcomes below. Nothing after quiescence
-- changes: supervision's stop, drain, settlement, and fatal delivery, the
-- dependency unwind, the reporting and flushing matrix, and the protected wait
-- for a worker that cannot stop, which is never detached.
--
-- __The application owns its types.__ The runner is polymorphic over the
-- dependencies and the services value. It enumerates no field of either,
-- imports no concrete application, and passes each callback only what it was
-- given. The services value is a snapshot assembled once by the startup
-- callback and passed as an ordinary immutable argument: there is no global or
-- central mutable availability registry, and nothing mutates the value. A
-- component that degrades after startup says so through its own handle, under
-- its own documented state ownership.
--
-- __The calling thread.__ Construction, startup, the action, and quiescence
-- all run on the thread that called the runner. Nothing forks the action to
-- race it against a monitor, and nothing promises to interrupt arbitrary 'IO': a
-- worker failure reaches the application at a checkpoint or a supervised
-- wait. This keeps the process main thread for a windowing owner, such as the
-- window host's owner loop in @hetoimasia-glfw@'s @runtime-glfw@ sublibrary,
-- which the action runs there.
--
-- __Outcomes.__
--
-- * The action returned, supervision settled nothing fatal, every disposal
--   succeeded, and the flush succeeded: its result is returned.
-- * Any synchronous failure — construction, startup, the action, a latched
--   supervised failure (even one the action caught, or one that arrived while
--   closing), or a quiescence or disposal failure after a successful action —
--   fails the run.
--   One managed terminal report is attempted after component disposal,
--   carrying the primary failure with its origin evidence and every retained
--   cleanup failure, and the failure is rethrown with its type, value, and
--   context. No report is attempted when a managed report has already failed,
--   when the failure was raised by a marked diagnostic, or when a terminal
--   boundary inside already reported it. The report's own synchronous failure
--   is discarded in favour of the failure being reported.
-- * The flush failed after a successful run: the flush's failure propagates,
--   with no report attempted and no retry.
-- * Cancellation: it propagates as itself once workers have drained and the
--   scopes have unwound, with no report and no flush.
--
-- The runtime never exits the host process. The executable owns the mapping of
-- a propagated failure, and of cancellation, to a non-zero exit status.
--
-- __What the runner does not own.__ Worker classification, checkpoints, waits,
-- the fatal latch, and closing are "Hetoimasia.Runtime.Supervision"'s; worker
-- ownership and the drain are "Hetoimasia.Foundation.Worker"'s; the finalization
-- matrix is "Hetoimasia.Runtime.Logging"'s; the report's fields are
-- "Hetoimasia.Runtime.Reporting"'s; the release rules are
-- "Hetoimasia.Foundation.Resource"'s. It defines no second version of any of
-- them.
--
-- __State.__ The runner holds no mutable state of its own. The dependency
-- scope's releases belong to 'withScoped', the worker and supervision state to
-- the one 'withSupervision' invocation, and the recorded reporting outcomes to
-- the logging lifetime, each under its own documented table. The services value
-- is the application's: created once by the startup callback on the calling
-- thread, read by the action on the same thread, never written, and gone when
-- the invocation returns. Nothing is shared between invocations or reset.
--
-- See @docs/resources.md@, \"Application lifecycle\", for the same contract in
-- prose with a composition example.
module Hetoimasia.Runtime.Application
  ( runScopedApplication
  , runScopedApplicationWithQuiescence
  , applicationComponent
  ) where

import Control.Concurrent.STM (STM, atomically)
import Control.Exception (ExceptionWithContext, SomeException, rethrowIO, tryWithContext)
import Data.Text (Text)
import GHC.Stack (HasCallStack)
import Hetoimasia.Foundation.Log (Component, unsafeComponent)
import Hetoimasia.Foundation.Resource (Scoped, withResourceLabelled, withScoped)
import Hetoimasia.Runtime.Logging (LoggingLifetime, lifetimeLogger, recordReport, recordedReports)
import Hetoimasia.Runtime.Reporting (ReportResult (..), reportTerminalFailureWith)
import Hetoimasia.Runtime.Supervision (RuntimeControl, checkRuntime, withSupervision)

-- | The component the runner's terminal report uses: the runtime's own, as
-- 'Hetoimasia.Runtime.runApplication' uses for its entries.
applicationComponent ∷ Component
applicationComponent = unsafeComponent "runtime"

-- | Run one application through the whole lifecycle the module header
-- describes, and return the action's result only once shutdown and logging
-- finalization have succeeded.
--
-- The first argument enters the logging lifetime over a logger the caller has
-- already constructed, such as
-- @'Hetoimasia.Runtime.Logging.withHandleLoggingLifetime' configuration stderr@
-- or @'Hetoimasia.Runtime.Logging.withLoggingLifetime' logger@. The runner
-- enters it itself, so the final flush is part of the lifecycle it returns
-- after. The text names the application in its terminal report.
--
-- The report's entry records the site that called this function.
--
-- It is 'runScopedApplicationWithQuiescence' with a quiescence action that does
-- nothing, which adds no observable step.
runScopedApplication
  ∷ HasCallStack
  ⇒ (∀ r. (LoggingLifetime → IO r) → IO r)
  → Text
  → Scoped dependencies
  → (dependencies → RuntimeControl → IO services)
  → (services → RuntimeControl → IO a)
  → IO a
runScopedApplication enterLifetime name dependencies =
  runScopedApplicationWithQuiescence enterLifetime name dependencies (\_ → pure ())

-- | 'runScopedApplication' with a quiescence action, the fourth argument, which
-- runs once with the constructed dependencies after the supervised region
-- exits and before supervision's boundary close, as the module header's
-- "Quiescence" describes.
--
-- The report's entry records the site that called this function.
runScopedApplicationWithQuiescence
  ∷ HasCallStack
  ⇒ (∀ r. (LoggingLifetime → IO r) → IO r)
  → Text
  → Scoped dependencies
  → (dependencies → STM ())
  → (dependencies → RuntimeControl → IO services)
  → (services → RuntimeControl → IO a)
  → IO a
runScopedApplicationWithQuiescence enterLifetime name dependencies quiesce startup action =
  enterLifetime $ \lifetime →
    reportOnce lifetime name $
      withScoped dependencies $ \built →
        withSupervision lifetime $ \control →
          withResourceLabelled quiescenceLabel (pure ()) (\() → atomically (quiesce built)) $ \() → do
            -- The guard is installed before the first checkpoint, so every exit
            -- from here quiesces before supervision closes.
            checkRuntime control
            services ← startup built control
            checkRuntime control
            result ← action services control
            checkRuntime control
            pure result

-- | The cleanup label a quiescence failure is retained under.
quiescenceLabel ∷ Text
quiescenceLabel = "application quiescence"

-- | The one managed terminal report, made after the work and every scope inside
-- it have unwound, unless a managed report on this lifetime has already failed.
reportOnce ∷ HasCallStack ⇒ LoggingLifetime → Text → IO a → IO a
reportOnce lifetime name work = do
  outcome ← tryWithContext work
  case outcome of
    Right result → pure result
    Left (failure ∷ ExceptionWithContext SomeException) → do
      recorded ← recordedReports lifetime
      if any reportFailed recorded
        then rethrowIO failure
        else
          reportTerminalFailureWith (recordReport lifetime) (lifetimeLogger lifetime) applicationComponent
            "Application failed" (pure [("application", name)]) (rethrowIO failure)
  where
    reportFailed (ReportFailed _) = True
    reportFailed _ = False
