-- | The pacing timer: one cancellable registration, whose wake is a flag composed in STM.
--
-- It is the owned timer of the Lua host's scheduler, in the shape the coordinator's driver needs: the
-- driver arms it for the next tick's due time, waits in one STM transaction for the flag beside every
-- other thing it waits for, and looks at the clock when it is raised. A wake is a notification only. It
-- is never evidence that a deadline passed, and a wake of a registration that was replaced, cancelled
-- or disposed is stale and ignored. What sleeps is the 'TimerBackend' the composition injects (the
-- threaded runtime's timer manager in production, a hand-fired one in a test), so no example sleeps.
--
-- = The backend's blocking contract
--
-- Arming and cancelling run under the repository's uninterruptible discipline, as a release does, so the backend the
-- composition injects must give them the same controlled blocking: both are finite, neither waits for another thread
-- or for the expiry, and a cancel that raises is a failure of that cleanup, accounted by the session. Masking does not
-- make arbitrary injected IO safe. The disposal itself is a registered finite release the session runs once, after every
-- role has finished, never inside a wait or a drain.
--
-- Owner: the coordinator's driver. Written by the driver (arming, disposing) and by the backend's wake
-- (the flag); read by the driver. Lifetime: the driver's scope; disposed on every way out of it.
module Hetoimasia.LuaEngine.Session.Timer
  ( Timer
  , BackendRaised (..)
  , newTimer
  , syncTimer
  , disposeTimer
  , timerWoken
  , clearTimerWake
  ) where

import Control.Concurrent.STM (STM, TVar, atomically, newTVarIO, readTVar, readTVarIO, writeTVar)
import Control.Exception (Exception (displayException), ExceptionWithContext (ExceptionWithContext), SomeException, onException, throwIO, tryWithContext, uninterruptibleMask_)
import Control.Monad (when)
import Data.Foldable (traverse_)
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Word (Word64)
import Hetoimasia.Foundation.Time (Duration, Instant, MonotonicSource, deadlineReached, readInstant, remainingUntil)
import Hetoimasia.Scripting.Lua.Scheduler (TimerBackend (..), registrationMicroseconds)

-- | What the injected backend raised, at the boundary where the timer calls it uninterruptibly: it is the backend's
-- own failure, never a delivery from outside, whatever its type (an exception of an asynchronous type that a cancel
-- action itself throws is a failure of that cleanup, as the foundation's contract has it for a release). The timer
-- raises it as a synchronous exception that keeps the original, with the context it carried, and says which call it
-- came from, so that the driver's accounting cannot mistake it for a cancellation of the caller.
data BackendRaised
  = -- | The backend's arm raised.
    ArmRaised !(ExceptionWithContext SomeException)
  | -- | The cancel action it handed out raised.
    CancelRaised !(ExceptionWithContext SomeException)

instance Show BackendRaised where
  show = Text.unpack . describeRaised

instance Exception BackendRaised where
  displayException = Text.unpack . describeRaised

describeRaised ∷ BackendRaised → Text
describeRaised = \case
  ArmRaised (ExceptionWithContext _ raised) → "the pacing timer's backend raised when it was armed: " <> Text.pack (displayException raised)
  CancelRaised (ExceptionWithContext _ raised) → "the pacing timer's backend raised when a registration was cancelled: " <> Text.pack (displayException raised)

-- | Run the backend's call, and keep what it raised, whole, as what the backend raised.
guardBackend ∷ (ExceptionWithContext SomeException → BackendRaised) → IO a → IO a
guardBackend wrap action = tryWithContext @SomeException action >>= either (throwIO . wrap) pure

data Registration = Registration
  { regGeneration ∷ !Word64
  , regDeadline ∷ !Instant
  }

data TimerState = TimerState
  { tsGeneration ∷ !Word64
  , tsLive ∷ !(Maybe Registration)
  , tsCancel ∷ !(Maybe (IO ()))
  , tsDisposed ∷ !Bool
  }

-- | The driver's timer.
data Timer = Timer
  { timerBackend ∷ !TimerBackend
  , timerState ∷ !(TVar TimerState)
  , timerFlag ∷ !(TVar Bool)
  }

-- | A timer with nothing armed.
newTimer ∷ TimerBackend → IO Timer
newTimer backend = Timer backend <$> newTVarIO (TimerState 0 Nothing Nothing False) <*> newTVarIO False

-- | Whether a wake has arrived that has not been looked at.
timerWoken ∷ Timer → STM Bool
timerWoken = readTVar . timerFlag

-- | Take the wake: the clock is about to be read.
clearTimerWake ∷ Timer → STM ()
clearTimerWake timer = writeTVar (timerFlag timer) False

-- | Make the registration match this deadline (none cancels it), leaving at most one. A deadline already
-- reached raises the wake instead of arming.
syncTimer ∷ Timer → MonotonicSource → Maybe Instant → IO ()
syncTimer timer clock target = do
  state ← readTVarIO (timerState timer)
  when (not (tsDisposed state)) $ case target of
    Nothing → cancelLive timer
    Just deadline → case tsLive state of
      Just registration | regDeadline registration == deadline → pure ()
      _ → do
        cancelLive timer
        now ← readInstant clock
        if deadlineReached now deadline
          then atomically (writeTVar (timerFlag timer) True)
          else arm timer deadline (remainingUntil now deadline)

-- Arming is uninterruptibly masked: the registration the backend made and the way to cancel it are never
-- separated by an asynchronous exception.
arm ∷ Timer → Instant → Duration → IO ()
arm timer deadline remaining = uninterruptibleMask_ $ do
  generation ← atomically $ do
    state ← readTVar (timerState timer)
    let issued = tsGeneration state + 1
    writeTVar (timerState timer) state {tsGeneration = issued, tsLive = Just (Registration issued deadline), tsCancel = Nothing}
    pure issued
  cancel ←
    guardBackend ArmRaised (backendArm (timerBackend timer) (registrationMicroseconds remaining) (wake timer generation))
      `onException` atomically (forget timer generation)
  atomically $ do
    state ← readTVar (timerState timer)
    when (fmap regGeneration (tsLive state) == Just generation) $
      writeTVar (timerState timer) state {tsCancel = Just cancel}

wake ∷ Timer → Word64 → IO ()
wake timer generation = atomically $ do
  state ← readTVar (timerState timer)
  when (not (tsDisposed state) && fmap regGeneration (tsLive state) == Just generation) $ do
    writeTVar (timerFlag timer) True
    writeTVar (timerState timer) state {tsLive = Nothing, tsCancel = Nothing}

forget ∷ Timer → Word64 → STM ()
forget timer generation = do
  state ← readTVar (timerState timer)
  when (fmap regGeneration (tsLive state) == Just generation) $
    writeTVar (timerState timer) state {tsLive = Nothing, tsCancel = Nothing}

cancelLive ∷ Timer → IO ()
cancelLive timer = uninterruptibleMask_ $ do
  cancel ← atomically $ do
    state ← readTVar (timerState timer)
    writeTVar (timerState timer) state {tsLive = Nothing, tsCancel = Nothing}
    pure (tsCancel state)
  traverse_ (guardBackend CancelRaised) cancel

-- | End the timer for good: cancel what is armed and ignore every wake and every request to arm.
disposeTimer ∷ Timer → IO ()
disposeTimer timer = uninterruptibleMask_ $ do
  cancel ← atomically $ do
    state ← readTVar (timerState timer)
    writeTVar (timerState timer) state {tsLive = Nothing, tsCancel = Nothing, tsDisposed = True}
    writeTVar (timerFlag timer) False
    pure (tsCancel state)
  traverse_ (guardBackend CancelRaised) cancel
