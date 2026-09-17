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
-- A boundary that must not miss a degradation waits for
-- 'awaitNotificationsSettled' first. A notification enters the session's
-- in-flight count before its wake call and leaves it only in the transaction
-- that records whatever that call left, so a boundary that finds the count at
-- zero has already seen every degradation those calls caused. The wait is
-- bounded by one empty-event post per notification in flight.
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
  , notifyOwner
  , awaitNotificationsSettled

    -- * Degradation and its one report
  , DegradationAttempt (..)
  , attemptDegradationReport
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

-- | Notify the session's owner that work was recorded, unless the path has
-- degraded.
--
-- It makes at most one wake call and never retries. An expected platform
-- failure degrades the path and retains the first such call's evidence for the
-- owner's one report; anything else 'wakeSession' raises propagates unchanged.
notifyOwner ∷ Notifier → IO WakeNotice
notifyOwner notifier =
  readTVarIO (notifierState notifier) >>= \case
    WakePathDegraded _ _ → pure NotificationSkipped
    WakePathHealthy → mask_ $ do
      -- Entered before the call and left only once whatever it found has been
      -- recorded, so a boundary that waits for the count to reach zero has
      -- already seen every degradation these calls caused.
      atomically (enter notifier)
      outcome ← wakeSession (notifierWake notifier) `onException` leave notifier Nothing
      case outcome of
        WakePosted → OwnerNotified <$ leave notifier Nothing
        WakeTerminal → NotificationTerminal <$ leave notifier Nothing
        WakeFailed reports → NotificationDegraded <$ leave notifier (Just reports)

-- | Wait until no notification is inside its wake call. It never retries on its
-- own and is bounded by one empty-event post per notification in flight, so an
-- owner boundary may wait on it.
awaitNotificationsSettled ∷ Notifier → STM ()
awaitNotificationsSettled notifier = readTVar (notifierInFlight notifier) >>= check . (<= 0)

enter ∷ Notifier → STM ()
enter notifier = modifyTVar' (notifierInFlight notifier) (+ 1)

-- | Record whatever the call left, then leave the count, in one transaction, so
-- no boundary can see the count fall without the degradation beside it.
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
attemptDegradationReport logger notifier = mask $ \restore →
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
