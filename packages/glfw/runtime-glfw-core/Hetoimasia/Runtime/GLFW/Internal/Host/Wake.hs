-- | The wake path: the session's degradation state, its notification
-- obligations, and the one guarded report of a degradation.
--
-- The wake path's state belongs to the session and its notifier, in
-- "Hetoimasia.GLFW.Internal.Notify"; every host over the session sees the same
-- state, and any thread may read it. The report is made on the process main
-- thread, the session's owner, at an owner boundary: after a loop, after
-- quiescence, or at the protected exit. This module holds no state of its own.
module Hetoimasia.Runtime.GLFW.Internal.Host.Wake
  ( -- * Reading the wake path
    hostWakePath
  , hostNotificationsInFlight
  , hostNotifier
  , hostWakeNotifier

    -- * Reporting a degradation
  , reportHostWakeDegradation
  , reportHostWakeDegradationAtExit
  , markedDegradationAttempt
  , promptAttempt
  , retainingReport
  ) where

import Control.Concurrent.STM (STM, atomically, readTVar)
import Control.Exception
  ( ExceptionWithContext
  , SomeException
  , mask
  , rethrowIO
  , tryWithContext
  , uninterruptibleMask_
  )
import Control.Monad (void)
import Data.Text (Text)
import GHC.Stack (HasCallStack)
import Hetoimasia.Foundation.Failure (Operation, operation)
import Hetoimasia.Foundation.Log (Logger)
import Hetoimasia.Foundation.Resource (withResourceLabelled)
import Hetoimasia.GLFW.Internal.Command (commandHostNotifier)
import Hetoimasia.GLFW.Internal.Notify
  ( DegradationAttempt
  , Notifier
  , attemptDegradationReportWith
  , awaitNotificationsSettled
  , notificationsInFlight
  )
import Hetoimasia.GLFW.Internal.Session (WakePath, ownerOperation, sessionWakePath)
import Hetoimasia.Runtime.GLFW.Internal.Host.State (WindowHost (..))
import Hetoimasia.Runtime.Reporting (markDiagnostic)

reportOperation ∷ Operation
reportOperation = operation "report wake degradation"

-- | Whether the session's wake path has degraded, and how its one diagnostic
-- report went. Any thread may read it; every host over the session sees the
-- same state.
hostWakePath ∷ WindowHost → STM WakePath
hostWakePath = readTVar . sessionWakePath . hostSession

-- | How many notification obligations the session's admissions and publications
-- have registered and not yet discharged. Any thread may read it; it is bounded
-- by the work committed and not yet notified.
hostNotificationsInFlight ∷ WindowHost → STM Int
hostNotificationsInFlight = notificationsInFlight . hostNotifier

-- | Claim the session's one degradation report, if one is still owed, at the
-- application's own owner boundary.
--
-- 'runWindowApplication' makes this attempt itself, after quiescence and the
-- worker drain, so an application that uses the ordinary runner never needs it.
-- It is here for one that owns a different shutdown.
--
-- Call it after quiescence. It waits for the notification obligations
-- outstanding, which is bounded only once admission and publication have closed;
-- called while they are open it can wait as long as a worker keeps publishing.
-- A cancellation during that wait completes it uninterruptibly and spends the
-- attempt before it is re-raised. Refuses other threads with
-- 'Hetoimasia.GLFW.Session.NotSessionOwner'.
reportHostWakeDegradation ∷ HasCallStack ⇒ Logger → WindowHost → IO DegradationAttempt
reportHostWakeDegradation logger host =
  ownerOperation (hostSession host) reportOperation [] $
    mask (\restore → settledAttempt restore logger host)

-- | The runner's own final boundary: the same attempt, over the restore its
-- caller already holds, checked as an owner operation exactly as
-- 'reportHostWakeDegradation' is.
reportHostWakeDegradationAtExit ∷ HasCallStack ⇒ (∀ a. IO a → IO a) → Logger → WindowHost → IO ()
reportHostWakeDegradationAtExit restore logger host =
  ownerOperation (hostSession host) reportOperation [] (void (settledAttempt restore logger host))

hostNotifier ∷ WindowHost → Notifier
hostNotifier = commandHostNotifier . hostCommands

-- | The session's notifier, for a thread that publishes to the owner and must
-- register and discharge its own wake obligation exactly as an admitted
-- completion notice does.
hostWakeNotifier ∷ WindowHost → Notifier
hostWakeNotifier = hostNotifier

-- | Wait for every registered notification obligation to be discharged, then
-- make the wake path's one guarded reporting attempt.
--
-- The wait is bounded only where no new obligation can be registered — after
-- quiescence has closed admission and publication. A boundary that runs while
-- they are open must use 'promptAttempt' instead, which claims what has already
-- been recorded and waits for nothing.
--
-- The caller has masked, and lends its @restore@ for the one part that must
-- stay interruptible: the write through the injected logger, so a cancellation
-- delivered while the attempt writes reaches it and is recorded as one. This is
-- never a release callback.
--
-- The wait is interruptible too, but a cancellation there may not abandon it: an
-- obligation may be inside a failing post that has not yet recorded what it
-- found, and nothing would be left to claim that degradation. So the wait is
-- completed uninterruptibly — bounded by one empty-event post per obligation
-- outstanding, with no new one possible once admission has closed — and the
-- attempt is then made before the cancellation is re-raised as the primary
-- failure. A failure the attempt raises is retained beside it.
settledAttempt ∷ HasCallStack ⇒ (∀ a. IO a → IO a) → Logger → WindowHost → IO DegradationAttempt
settledAttempt restore logger host =
  tryWithContext (restore (atomically (awaitNotificationsSettled notifier))) >>= \case
    Right () → attempt
    Left interrupted → do
      uninterruptibleMask_ (atomically (awaitNotificationsSettled notifier))
      tryWithContext attempt >>= \case
        Right _ → rethrowIO (interrupted ∷ ExceptionWithContext SomeException)
        Left failed →
          withResourceLabelled
            wakeReportLabel
            (pure ())
            (\() → rethrowIO (failed ∷ ExceptionWithContext SomeException))
            (\() → rethrowIO interrupted)
  where
    notifier = hostNotifier host
    attempt = markedDegradationAttempt restore logger notifier

-- | One wake degradation warning attempt, carrying the runtime's
-- diagnostic-failure identity out of the host.
--
-- The attempt itself is "Hetoimasia.GLFW.Internal.Notify"'s: the @model@
-- component owns the claim, the write, and the settlement, and depends on no
-- runtime module. The identity is added here, where this sublibrary already
-- owns the attempt and already depends on the runtime, so a sink failure that
-- leaves the host is one
-- 'Hetoimasia.Runtime.Reporting.reportTerminalFailureWith' will not write
-- through again and 'Hetoimasia.Runtime.Logging.withLoggingLifetime' will not
-- flush through. Nothing else about the attempt changes: its one-attempt rule,
-- its recorded outcome, and the exception's own type, value, and context are
-- the notifier's, and a cancellation is left exactly as it arrived.
--
-- The mark is what a failure leaving as primary carries. A failure retained
-- beside an application primary is carried by 'recordingDiagnostics' instead,
-- which records it on the logging lifetime rather than marking a failure that
-- no diagnostic raised.
markedDegradationAttempt
  ∷ HasCallStack ⇒ (∀ a. IO a → IO a) → Logger → Notifier → IO DegradationAttempt
markedDegradationAttempt restore logger notifier =
  markDiagnostic (attemptDegradationReportWith restore logger notifier)

-- | The wake path's one guarded reporting attempt, without waiting for
-- anything.
--
-- It claims a degradation already recorded and leaves one still being recorded
-- to the boundary that runs after quiescence, so it can be used while
-- admissions and publications are still being made without ever waiting on a
-- worker that keeps making them.
promptAttempt ∷ HasCallStack ⇒ (∀ a. IO a → IO a) → Logger → WindowHost → IO ()
promptAttempt restore logger host = void (markedDegradationAttempt restore logger (hostNotifier host))

-- | Run @body@, then make the reporting attempt, whatever @body@ did.
--
-- The whole sequence is masked and @body@ runs under the restore, so nothing can
-- be delivered in the handoff between the body ending and the attempt being
-- protected; the attempt is lent that same restore for its logger write.
--
-- A failure the attempt raises after a successful body fails the caller. After a
-- failing or cancelled body the body's failure stays primary and the attempt's
-- is retained beside it as cleanup evidence, carried by a release that only
-- rethrows what was already caught.
retainingReport ∷ ((∀ a. IO a → IO a) → IO ()) → IO r → IO r
retainingReport attempt body = mask $ \restore → do
  outcome ← tryWithContext (restore body)
  reported ← tryWithContext (attempt restore)
  case (outcome, reported) of
    (Right result, Right ()) → pure result
    (Right _, Left failed) → rethrowIO (failed ∷ ExceptionWithContext SomeException)
    (Left primary, Right ()) → rethrowIO (primary ∷ ExceptionWithContext SomeException)
    (Left primary, Left failed) →
      withResourceLabelled
        wakeReportLabel
        (pure ())
        (\() → rethrowIO (failed ∷ ExceptionWithContext SomeException))
        (\() → rethrowIO (primary ∷ ExceptionWithContext SomeException))

-- | The cleanup label a failed reporting attempt is retained under.
wakeReportLabel ∷ Text
wakeReportLabel = "glfw wake degradation report"
