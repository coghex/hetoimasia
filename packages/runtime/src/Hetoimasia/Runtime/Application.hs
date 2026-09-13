-- | The generic application lifecycle.
--
-- 'runScopedApplication' sits beside 'Hetoimasia.Runtime.runApplication', the
-- thin runner over a supplied logger, which keeps its module, signature,
-- behavior, and examples. It composes the runtime's other boundaries in one
-- fixed order and adds no mechanics of its own:
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
--    ("Hetoimasia.Runtime.Supervision").
-- 5. The startup callback runs on the calling thread with the dependencies and
--    the 'RuntimeControl'. It may start and acknowledge workers, and it returns
--    the application's immutable services value.
-- 6. A checkpoint runs before that value is handed over.
-- 7. The action runs on the calling thread with the services value and the
--    control, and a checkpoint runs before its result is accepted.
-- 8. Supervision closes: registration closes, every live worker is asked to
--    stop, every worker is drained, and every outcome not yet handled is
--    settled, with the fatal latch rethrown.
-- 9. The dependency scope unwinds: dependents are disposed before their
--    dependencies, and each composite keeps its declared internal order.
-- 10. A failed run gets one managed terminal report while the logger is live.
-- 11. The logging lifetime makes its one permitted final flush.
-- 12. The result is returned, or the failure is rethrown preservingly.
--
-- Steps 8 to 12 happen on every exit path: construction failure (from step 9),
-- startup failure, action failure, a supervisor-detected failure, and owner
-- cancellation, which skips steps 10 and 11.
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
-- __The calling thread.__ Construction, startup, and the action all run on the
-- thread that called 'runScopedApplication'. Nothing forks the action to race
-- it against a monitor, and nothing promises to interrupt arbitrary 'IO': a
-- worker failure reaches the application at a checkpoint or a supervised
-- wait. This keeps the process main thread for a future windowing owner.
--
-- __Outcomes.__
--
-- * The action returned, supervision settled nothing fatal, every disposal
--   succeeded, and the flush succeeded: its result is returned.
-- * Any synchronous failure — construction, startup, the action, a latched
--   supervised failure (even one the action caught, or one that arrived while
--   closing), or a disposal failure after a successful action — fails the run.
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
  , applicationComponent
  ) where

import Control.Exception (ExceptionWithContext, SomeException, rethrowIO, tryWithContext)
import Data.Text (Text)
import GHC.Stack (HasCallStack)
import Hetoimasia.Foundation.Log (Component, unsafeComponent)
import Hetoimasia.Foundation.Resource (Scoped, withScoped)
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
runScopedApplication
  ∷ HasCallStack
  ⇒ (∀ r. (LoggingLifetime → IO r) → IO r)
  → Text
  → Scoped dependencies
  → (dependencies → RuntimeControl → IO services)
  → (services → RuntimeControl → IO a)
  → IO a
runScopedApplication enterLifetime name dependencies startup action =
  enterLifetime $ \lifetime →
    reportOnce lifetime name $
      withScoped dependencies $ \built →
        withSupervision lifetime $ \control → do
          checkRuntime control
          services ← startup built control
          checkRuntime control
          result ← action services control
          checkRuntime control
          pure result

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
