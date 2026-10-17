-- | The owned timer: one cancellable registration, composable in STM.
--
-- A scheduler has at most one live registration at a time. It is armed for the
-- earliest elapsed deadline of the owner's waiting tasks, re-armed when that
-- deadline changes, and cancelled when nothing waits and when the scheduler
-- stops. Its wake is a flag the owner reads in STM beside its stop request, its
-- admissions, its control requests and its grants, so the owner sleeps in one
-- place and nothing polls.
--
-- = A wake is a notification
--
-- A wake says only that the owner should look at its clock again. It is never
-- evidence that a deadline passed: the owner compares its TIME-1 source with the
-- deadlines it holds, and a wake that comes early (a registration clamped to
-- 'maxRegistration', a backend that fires ahead of its time) finds nothing due
-- and the owner arms again. A wake that belongs to a registration that was
-- cancelled or replaced is stale and is ignored, as is any wake after
-- 'disposeTimer', so an obsolete wake can neither ready a task nor recreate
-- demand for a timer that has been disposed of.
--
-- = Range and granularity
--
-- Registrations are in whole microseconds, as the system timer manager takes
-- them. A remaining duration is rounded up, so a registration never fires before
-- its time and never for less than one microsecond, and it is clamped to
-- 'maxRegistration', so a distant deadline never reaches the manager's own
-- arithmetic limits: a deadline farther away than that is reached by a chain of
-- wakes, each followed by a look at the clock. None of this defines a clock.
--
-- = The seam
--
-- What actually sleeps is a 'TimerBackend'. Production uses the threaded
-- runtime's timer manager, which has no thread of its own for this and lets the
-- registration be cancelled; a test supplies its own and fires its wakes by
-- hand, so no example sleeps.
module Hetoimasia.Scripting.Lua.Scheduler.Timer
  ( -- * The seam
    TimerBackend (..)
  , systemTimerBackend
  , maxRegistration
  , registrationMicroseconds

    -- * The timer
  , Timer
  , newTimer
  , syncTimer
  , disposeTimer
  , timerWoken
  , clearTimerWake
  ) where

import Control.Concurrent.STM
  ( STM
  , TVar
  , atomically
  , newTVarIO
  , readTVar
  , readTVarIO
  , writeTVar
  )
import Control.Exception (mask_, onException)
import Control.Monad (when)
import Data.Word (Word64)
import GHC.Event (getSystemTimerManager, registerTimeout, unregisterTimeout)
import Hetoimasia.Foundation.Time
  ( Duration
  , Instant
  , MonotonicSource
  , deadlineReached
  , durationNanoseconds
  , readInstant
  , remainingUntil
  )

-- | What sleeps.
newtype TimerBackend = TimerBackend
  { backendArm ∷ Int → IO () → IO (IO ())
    -- ^ Arm a registration for this many microseconds, at least one and at most
    -- 'maxRegistration', that calls the given action once when it expires.
    -- Answers the action that cancels it. Cancelling a registration that has
    -- fired, or twice, is harmless.
  }

-- | The threaded runtime's timer manager.
--
-- It needs the threaded runtime, which every program that runs Lua needs for its
-- own reasons; arming raises the runtime's error on the single-threaded one.
systemTimerBackend ∷ TimerBackend
systemTimerBackend = TimerBackend $ \microseconds callback → do
  manager ← getSystemTimerManager
  key ← registerTimeout manager microseconds callback
  pure (unregisterTimeout manager key)

-- | The longest registration: one hour, in microseconds.
maxRegistration ∷ Int
maxRegistration = 3600 * 1000 * 1000

-- | The registration for a remaining duration: whole microseconds, rounded up,
-- at least one, at most 'maxRegistration'.
registrationMicroseconds ∷ Duration → Int
registrationMicroseconds remaining =
  fromIntegral (min (toInteger maxRegistration) (max 1 ceilingMicroseconds))
  where
    nanoseconds = toInteger (durationNanoseconds remaining)
    ceilingMicroseconds = (nanoseconds + 999) `div` 1000

-- | A registration that has been armed and has not fired.
data Registration = Registration
  { registrationGeneration ∷ !Word64
  , registrationDeadline ∷ !Instant
  }

data TimerState = TimerState
  { stateGeneration ∷ !Word64
    -- ^ The last generation issued. A wake counts only for the live one.
  , stateLive ∷ !(Maybe Registration)
  , stateCancel ∷ !(Maybe (IO ()))
  , stateDisposed ∷ !Bool
  }

-- | One owner's timer.
data Timer = Timer
  { timerBackend ∷ !TimerBackend
  , timerState ∷ !(TVar TimerState)
  , timerFlag ∷ !(TVar Bool)
  }

-- | A timer with nothing armed.
newTimer ∷ TimerBackend → IO Timer
newTimer backend =
  Timer backend
    <$> newTVarIO (TimerState 0 Nothing Nothing False)
    <*> newTVarIO False

-- | Whether a wake has arrived that the owner has not yet looked at. Retry-free,
-- so the owner composes it with its other conditions.
timerWoken ∷ Timer → STM Bool
timerWoken = readTVar . timerFlag

-- | Take the wake: the owner is about to look at its clock.
clearTimerWake ∷ Timer → STM ()
clearTimerWake timer = writeTVar (timerFlag timer) False

-- | Make the registration match the earliest deadline the owner holds, and
-- leave at most one.
--
-- With no deadline the registration is cancelled. With one, a registration that
-- is already armed for exactly it is kept, and any other is cancelled before the
-- new one is armed, so two are never live. A deadline already reached by the
-- time of arming raises the wake flag instead of arming. Called only from the
-- owner's thread, which is why the two halves of arming need no lock between
-- them; only a wake arrives from elsewhere, and it is a transaction.
syncTimer ∷ Timer → MonotonicSource → Maybe Instant → IO ()
syncTimer timer clock target = do
  state ← readTVarIO (timerState timer)
  when (not (stateDisposed state)) $ case target of
    Nothing → cancelLive timer
    Just deadline → case stateLive state of
      Just registration | registrationDeadline registration == deadline → pure ()
      _ → do
        cancelLive timer
        now ← readInstant clock
        if deadlineReached now deadline
          then atomically (writeTVar (timerFlag timer) True)
          else arm timer deadline (remainingUntil now deadline)

-- | Arm a registration. The generation and the live record are published before
-- the backend is asked, so a wake that arrives at once finds them. The whole of
-- it is masked, so the registration the backend made and the action that cancels
-- it are never separated by an asynchronous exception: the timer owns it from
-- the moment it exists.
arm ∷ Timer → Instant → Duration → IO ()
arm timer deadline remaining = mask_ $ do
  generation ← atomically $ do
    state ← readTVar (timerState timer)
    let issued = stateGeneration state + 1
    writeTVar (timerState timer) state
      { stateGeneration = issued
      , stateLive = Just (Registration issued deadline)
      , stateCancel = Nothing
      }
    pure issued
  cancel ←
    backendArm (timerBackend timer) (registrationMicroseconds remaining) (wake timer generation)
      `onException` atomically (retire timer generation)
  atomically $ do
    state ← readTVar (timerState timer)
    -- A registration that has already fired has nothing to cancel.
    when (fmap registrationGeneration (stateLive state) == Just generation) $
      writeTVar (timerState timer) state {stateCancel = Just cancel}

-- | A registration's wake. It counts only for the live generation of a timer
-- that has not been disposed of, and then it is spent.
wake ∷ Timer → Word64 → IO ()
wake timer generation = atomically $ do
  state ← readTVar (timerState timer)
  when (not (stateDisposed state) && fmap registrationGeneration (stateLive state) == Just generation) $ do
    writeTVar (timerFlag timer) True
    writeTVar (timerState timer) state {stateLive = Nothing, stateCancel = Nothing}

-- | Forget a generation that never got a registration.
retire ∷ Timer → Word64 → STM ()
retire timer generation = do
  state ← readTVar (timerState timer)
  when (fmap registrationGeneration (stateLive state) == Just generation) $
    writeTVar (timerState timer) state {stateLive = Nothing, stateCancel = Nothing}

-- | Cancel the live registration, if there is one.
cancelLive ∷ Timer → IO ()
cancelLive timer = mask_ $ do
  cancel ← atomically $ do
    state ← readTVar (timerState timer)
    writeTVar (timerState timer) state {stateLive = Nothing, stateCancel = Nothing}
    pure (stateCancel state)
  sequence_ cancel

-- | End the timer for good: cancel what is armed, and ignore every wake and
-- every request to arm from now on.
disposeTimer ∷ Timer → IO ()
disposeTimer timer = mask_ $ do
  cancel ← atomically $ do
    state ← readTVar (timerState timer)
    writeTVar (timerState timer) state {stateLive = Nothing, stateCancel = Nothing, stateDisposed = True}
    writeTVar (timerFlag timer) False
    pure (stateCancel state)
  sequence_ cancel
