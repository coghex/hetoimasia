-- | The ordinary window application runner, and the diagnostics recording
-- both runners share.
--
-- The runner runs on the process main thread, which enters the logging
-- lifetime, builds the host, and runs the application's own work; the
-- runtime's managed application owns the order of startup, supervision, and
-- shutdown, and this module adds only the host's quiescence and its final wake
-- report to it. It keeps no state: the logging lifetime it records onto is the
-- application's.
module Hetoimasia.Runtime.GLFW.Internal.Host.Application
  ( runWindowApplication
  , recordingDiagnostics
  ) where

import Control.Exception (ExceptionWithContext (ExceptionWithContext), SomeException, rethrowIO, tryWithContext)
import Data.Text (Text)
import GHC.Stack (HasCallStack)
import Hetoimasia.Foundation.Resource (Scoped, cleanupFailureException, cleanupFailuresInContext, withScoped)
import Hetoimasia.Runtime.Application (runManagedApplication)
import Hetoimasia.Runtime.GLFW.Internal.Host.Construction (quiesceWindowHost)
import Hetoimasia.Runtime.GLFW.Internal.Host.State (WindowHost)
import Hetoimasia.Runtime.GLFW.Internal.Host.Wake (reportHostWakeDegradationAtExit, retainingReport)
import Hetoimasia.Runtime.Logging (LoggingLifetime, lifetimeLogger, recordReport)
import Hetoimasia.Runtime.Reporting (ReportResult (ReportFailed), raisedByDiagnostic)
import Hetoimasia.Runtime.Supervision (RuntimeControl)

-- | 'Hetoimasia.Runtime.Application.runManagedApplication' with the host's
-- quiescence action and its final notification boundary: the fourth argument
-- finds the host among the application's dependencies.
--
-- The host's dependencies are a managed lifetime rather than a bare scope, so
-- the runner's own order gains one component-owned step and nothing else: the
-- finite quiescence transaction closes admission, publication, and every input
-- feed; supervision then stops and drains every worker; and only then, with
-- every dependency and the application's logger still live, the host waits for
-- the notification obligations its admissions and publications registered and
-- makes the wake path's one guarded reporting attempt. Nothing new can be
-- admitted or published by then, so that attempt cannot be outrun.
--
-- It is the ordinary boundary, so an application needs no reporting call of its
-- own; 'reportHostWakeDegradation' stays available for one that owns a
-- different shutdown. The attempt runs on the calling thread as ordinary
-- interruptible work, not inside a release: a failing sink after a successful
-- run fails the run, and after a failing or cancelled one the original failure
-- stays primary with the attempt's retained beside it.
runWindowApplication
  ∷ HasCallStack
  ⇒ (∀ r. (LoggingLifetime → IO r) → IO r)
  → Text
  → Scoped dependencies
  → (dependencies → WindowHost)
  → (dependencies → RuntimeControl → IO services)
  → (services → RuntimeControl → IO a)
  → IO a
runWindowApplication enterLifetime name dependencies host startup action =
  enterLifetime $ \lifetime →
    runManagedApplication
      (\use → use lifetime)
      name
      ( \use →
          recordingDiagnostics lifetime $
            withScoped dependencies $ \built →
              retainingReport
                (\restore → reportHostWakeDegradationAtExit restore (lifetimeLogger lifetime) (host built))
                (use built)
      )
      (quiesceWindowHost . host)
      startup
      action

-- | Record on the logging lifetime every host lifecycle diagnostic that failed
-- inside @work@, then let what @work@ raised through unchanged.
--
-- A wake degradation warning and a retirement stall diagnostic are both written
-- through the application's own sink, and both leave 'markDiagnostic''s mark on
-- the failure a failing sink raises. When that failure is the one leaving the
-- host, the mark is enough: 'Hetoimasia.Runtime.Reporting.reportTerminalFailure'
-- and 'Hetoimasia.Runtime.Logging.withLoggingLifetime' both read it off the
-- context they are handed.
--
-- When an application failure is already primary, they do not: the boundaries
-- that retain a failed warning — 'retainingReport' and the protected exit's
-- 'settleProtectedOutcome' — keep the application's failure primary, which is
-- what it is, and carry the warning beside it as labelled cleanup evidence.
-- Marking that primary would say a diagnostic raised it, which is false. So the
-- warning is recorded here instead, as the 'ReportFailed' outcome the logging
-- lifetime already has a place for, exactly as a runtime-managed report records
-- its own failed attempt. 'Hetoimasia.Runtime.Application.reportOnce' then makes
-- no further write through that sink, and the lifetime attempts no final flush
-- through it.
--
-- It is the runners' own step, so it wraps everything inside them that can make
-- or retain one of these attempts, and nothing else: it reports nothing, writes
-- nothing, changes no outcome, and adds no annotation to the failure it lets
-- through. A cancellation carries no mark and records nothing. Runtime policy
-- is unchanged; this only tells the lifetime what the host already found.
recordingDiagnostics ∷ LoggingLifetime → IO r → IO r
recordingDiagnostics lifetime work =
  tryWithContext work >>= \case
    Right result → pure result
    Left caught → do
      mapM_ (recordReport lifetime . ReportFailed) (failedDiagnosticsOf caught)
      rethrowIO (caught ∷ ExceptionWithContext SomeException)

-- | The failed lifecycle diagnostics one propagating failure carries: the
-- failure itself when a diagnostic raised it, and every marked failure retained
-- beside it as cleanup evidence, in the order the boundaries found them.
--
-- 'cleanupFailuresInContext' already reports each distinct retained failure
-- once, however many routes reach it, so a warning retained through several
-- scopes is recorded once.
failedDiagnosticsOf ∷ ExceptionWithContext SomeException → [ExceptionWithContext SomeException]
failedDiagnosticsOf caught@(ExceptionWithContext context _) =
  [caught | raisedByDiagnostic context] <> filter diagnostic retained
  where
    retained = map cleanupFailureException (cleanupFailuresInContext context)
    diagnostic (ExceptionWithContext carried _) = raisedByDiagnostic carried
