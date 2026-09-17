-- | The notification policy over a session's wake capability.
--
-- "Hetoimasia.GLFW.Internal.Session" classifies one wake call and deliberately
-- chooses no policy. This module is that policy, and the one place command
-- admission and demand publication reach the owner from: a 'Notifier' pairs a
-- session's 'SessionWake' with the session's own 'WakePath' state, so every
-- host over one session — including hosts that borrow it in turn — shares one
-- degradation and one diagnostic report, and a later session starts healthy
-- with a capability and a state of its own.
--
-- = Degradation
--
-- A notification is a hint. The command queue and the demand slots are
-- authoritative, so a notification that fails changes nothing about the work
-- that had already been recorded.
--
-- = The obligation
--
-- An admission or a publication registers its notification obligation with
-- 'registerNotification' in the very transaction that commits it, so a
-- transaction that rolls back, or one that admitted or published nothing,
-- registers none. From that commit the obligation is visible to every boundary,
-- before the notifying thread has run another instruction.
--
-- 'dischargeNotification' discharges it exactly once: it makes at most one wake
-- call, and then records what that call left and leaves the obligation in one
-- transaction, so no boundary can see the obligation go without the degradation
-- it caused beside it. A boundary that waits for 'awaitNotificationsSettled'
-- has therefore seen every degradation that committed work could still cause.
-- The wait is bounded by one empty-event post per obligation outstanding.
--
-- The first expected platform failure — the 'WakeFailed' outcome, with the
-- evidence attributed to that call alone — degrades the session's wake path,
-- retaining that evidence. Every later notification over that session then
-- skips the native call entirely, and the owner's finite idle wait is the
-- bounded polling that keeps work moving. Nothing is retried, no ticket or slot
-- changes, and no admitted work is reclassified.
--
-- A programming or lifetime violation is not degraded around: 'wakeSession'
-- raises it, and it propagates to whichever thread was notifying, with the
-- command or publication it had already committed still accepted.
--
-- = The one report
--
-- Degradation owes exactly one guarded diagnostic attempt.
-- 'attemptDegradationReport' claims it at a safe owner boundary — outside
-- transactions, callbacks, releases, and the wake lifetime's native exclusion —
-- and writes one structured warning under @glfw.wake@ through the logger the
-- application injects. The obligation is claimed once: a filtered entry, a
-- failing sink, and a cancellation each spend the attempt, are recorded in the
-- state, and are never retried. A sink failure and a cancellation propagate as
-- themselves, as every logging attempt does. Neither undoes the degradation.
--
-- = State
--
-- This module owns none of its own. The 'WakePath' it reads and writes and the
-- in-flight count it keeps both belong to the session, live as long as it does,
-- and are never reset.
module Hetoimasia.GLFW.Internal.Notify
  ( -- * Notifiers
    Notifier
  , sessionNotifier
  , notifierPath

    -- * Notifying the owner
  , WakeNotice (..)
  , registerNotification
  , dischargeNotification
  , awaitNotificationsSettled
  , notificationsInFlight

    -- * Degradation and its one report
  , DegradationAttempt (..)
  , attemptDegradationReport
  , attemptDegradationReportWith
  , wakeComponent
  ) where

import Control.Concurrent.STM (STM, TVar, atomically, check, modifyTVar', readTVar, readTVarIO, writeTVar)
import Control.Exception
  ( ExceptionWithContext (ExceptionWithContext)
  , onException
  , SomeAsyncException
  , SomeException
  , fromException
  , mask
  , mask_
  , rethrowIO
  , tryWithContext
  , uninterruptibleMask_
  )
import Data.Maybe (isJust)
import Data.Text (Text)
import qualified Data.Text as Text
import GHC.Stack (HasCallStack)
import Hetoimasia.Foundation.Log (Component, Logger, logWarning, unsafeComponent)
import Hetoimasia.GLFW.Internal.Session
  ( DegradationReport (..)
  , NativeError (..)
  , Reports (..)
  , Session
  , SessionWake
  , WakeOutcome (..)
  , WakePath (..)
  , sessionNotificationsInFlight
  , sessionWake
  , sessionWakePath
  , wakeSession
  )

-- | One session's wake capability beside that session's wake-path state. Its
-- representation is private: it holds no native handle, no session, and no
-- authority beyond posting the session's own empty event.
data Notifier = Notifier
  { notifierWake ∷ !SessionWake
  , notifierState ∷ !(TVar WakePath)
  , notifierInFlight ∷ !(TVar Int)
  }

-- | The notifier for a session. Every notifier for one session shares its
-- degradation.
sessionNotifier ∷ Session → Notifier
sessionNotifier session =
  Notifier (sessionWake session) (sessionWakePath session) (sessionNotificationsInFlight session)

-- | The wake-path state a notifier follows, for the owner boundary that reports
-- a degradation and for examples that assert one.
notifierPath ∷ Notifier → TVar WakePath
notifierPath = notifierState

-- | The component the degradation warning is written under.
wakeComponent ∷ Component
wakeComponent = unsafeComponent "glfw.wake"

-- | What one notification did.
data WakeNotice
  = OwnerNotified
    -- ^ The empty event was posted.
  | NotificationTerminal
    -- ^ The session has begun closing or has closed: GLFW was not entered.
  | NotificationDegraded
    -- ^ An expected platform failure. The session's wake path is degraded from
    -- now on, with this call's evidence retained if it was the first.
  | NotificationSkipped
    -- ^ The session's wake path had already degraded: no native call was made.
  deriving (Eq, Show)

-- | Register the notification an admission or a publication owes, in the
-- transaction that commits it. Never retries.
registerNotification ∷ Notifier → STM ()
registerNotification notifier = modifyTVar' (notifierInFlight notifier) (+ 1)

-- | Discharge one registered obligation, waking the session's owner unless the
-- path has already degraded.
--
-- It makes at most one wake call and never retries. An expected platform
-- failure degrades the path and retains the first such call's evidence for the
-- owner's one report; anything else 'wakeSession' raises propagates unchanged,
-- with the obligation discharged first either way.
dischargeNotification ∷ Notifier → IO WakeNotice
dischargeNotification notifier =
  readTVarIO (notifierState notifier) >>= \case
    WakePathDegraded _ _ → NotificationSkipped <$ leave notifier Nothing
    WakePathHealthy → mask_ $ do
      outcome ← wakeSession (notifierWake notifier) `onException` leave notifier Nothing
      case outcome of
        WakePosted → OwnerNotified <$ leave notifier Nothing
        WakeTerminal → NotificationTerminal <$ leave notifier Nothing
        WakeFailed reports → NotificationDegraded <$ leave notifier (Just reports)

-- | Wait until every registered obligation has been discharged. It is bounded
-- by one empty-event post per obligation outstanding, so an owner boundary may
-- wait on it.
awaitNotificationsSettled ∷ Notifier → STM ()
awaitNotificationsSettled notifier = notificationsInFlight notifier >>= check . (<= 0)

-- | How many obligations are registered and not yet discharged.
notificationsInFlight ∷ Notifier → STM Int
notificationsInFlight = readTVar . notifierInFlight

-- | Record whatever the call left and discharge the obligation in one
-- transaction, so no boundary can see the obligation go without the degradation
-- it caused beside it.
leave ∷ Notifier → Maybe Reports → IO ()
leave notifier recorded =
  uninterruptibleMask_ . atomically $ do
    mapM_ (degrade notifier) recorded
    modifyTVar' (notifierInFlight notifier) (subtract 1)

-- | Record the degradation, keeping the evidence of the failure that degraded
-- the path first. Never retries.
degrade ∷ Notifier → Reports → STM ()
degrade notifier reports =
  readTVar (notifierState notifier) >>= \case
    WakePathHealthy → writeTVar (notifierState notifier) (WakePathDegraded reports DegradationOwed)
    WakePathDegraded _ _ → pure ()

-- | What one attempt at the degradation report did.
data DegradationAttempt
  = NoDegradationDue
    -- ^ The path is healthy, or its one attempt has already been spent.
  | DegradationReportAttempted
    -- ^ The attempt completed: the entry was written, or the logger filtered
    -- it. Either way the attempt is spent.
  deriving (Eq, Show)

-- | Claim the session's one degradation report, if one is owed, and write it
-- through the injected logger at an owner boundary.
--
-- A sink failure or a cancellation is recorded in the state and propagates as
-- itself. Neither is retried, and neither undoes the degradation.
attemptDegradationReport ∷ HasCallStack ⇒ Logger → Notifier → IO DegradationAttempt
attemptDegradationReport logger notifier =
  mask (\restore → attemptDegradationReportWith restore logger notifier)

-- | 'attemptDegradationReport' for a caller that has already masked, and whose
-- own @restore@ it uses for the one part that must stay interruptible: the
-- write through the logger. Claiming and settling the attempt are non-blocking
-- transactions, so nothing can be delivered between them.
attemptDegradationReportWith
  ∷ HasCallStack ⇒ (∀ a. IO a → IO a) → Logger → Notifier → IO DegradationAttempt
attemptDegradationReportWith restore logger notifier =
  atomically claim >>= \case
    Nothing → pure NoDegradationDue
    Just reports →
      tryWithContext (restore (logWarning logger wakeComponent message (fields reports))) >>= \case
        Right () → DegradationReportAttempted <$ atomically (settle DegradationReported)
        Left caught@(ExceptionWithContext _ failure) → do
          let outcome
                | isJust (fromException failure ∷ Maybe SomeAsyncException) = DegradationReportInterrupted
                | otherwise = DegradationReportFailed
          atomically (settle outcome)
          rethrowIO (caught ∷ ExceptionWithContext SomeException)
  where
    state = notifierState notifier

    message = "The native wake path degraded; the owner falls back to its finite idle wait"

    claim =
      readTVar state >>= \case
        WakePathDegraded reports DegradationOwed → do
          writeTVar state (WakePathDegraded reports DegradationReporting)
          pure (Just reports)
        _ → pure Nothing

    settle outcome =
      readTVar state >>= \case
        WakePathDegraded reports DegradationReporting → writeTVar state (WakePathDegraded reports outcome)
        _ → pure ()

    fields reports =
      [ ("reported", shown (length (reportedErrors reports)))
      , ("lost", shown (fromIntegral (reportsLost reports)))
      , ("faults", shown (fromIntegral (callbackFaults reports)))
      ]
        <> case reportedErrors reports of
          [] → []
          first : _ → [("code", shown (nativeErrorCode first)), ("description", nativeErrorDescription first)]

    shown ∷ Int → Text
    shown = Text.pack . show
