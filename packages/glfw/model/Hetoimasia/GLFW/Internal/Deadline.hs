-- | The process-level deadline an application puts on native initialization.
--
-- @glfwInit@ runs on the process main thread and can block there for good (the
-- Cocoa case is described in @docs/glfw.md@, Entry step 6), and a blocked main
-- thread cannot be unwound from Haskell: there is no exception to deliver to a
-- thread that is inside a foreign call, and no cleanup that may wait for it. So
-- the only answer a deadline can give is the one vision V-3 allows an
-- application for a stalled quit: after an application-chosen bound it names
-- what is still running, makes a bounded best-effort report, and ends the
-- /process/ without unwinding, leaving reclamation to the operating system.
--
-- = Who owns what
--
-- The /policy/ is the application's: it chooses whether to have a deadline, the
-- bound, and what is said ('InitializationDeadline'), and it injects the report
-- as an action over its own logger, so the session stays logger-free and this
-- package writes to no handle of its own. The /mechanism/ is this module's: a
-- guard that brackets the one native call, owns its timer thread, and decides
-- exactly once whether initialization returned in time or the deadline expired.
-- The exit itself is a 'Native' operation, so a CPU example can observe it
-- without ending its own process.
--
-- = States
--
-- Each guarded call has one state cell, written by a single transaction on each
-- side, so completion and expiry are never both decided:
--
-- +-----------+---------------------------------------+-------------------------------+
-- | State     | Entered by                            | Left by                       |
-- +===========+=======================================+===============================+
-- | Pending   | the guard, before the call            | completion or expiry          |
-- +-----------+---------------------------------------+-------------------------------+
-- | Retired   | the guarded call returning, raising,  | never: the timer thread then  |
-- |           | or being cancelled                    | ends and is joined            |
-- +-----------+---------------------------------------+-------------------------------+
-- | Expired   | the timer thread, once the bound      | never: the process ends       |
-- |           | has passed with the state Pending     |                               |
-- +-----------+---------------------------------------+-------------------------------+
--
-- A retired timer therefore cannot end the process later, and a later guarded
-- call has a cell and a timer thread of its own.
--
-- = The timer thread
--
-- It is started under mask with its cleanup registered in the same step, and
-- stopped and joined on every way out of the guarded call: a normal return, a
-- raised exception, and cancellation. It leaves nothing behind. When the
-- deadline expires it runs the injected report on a thread of its own and waits
-- for it for at most 'reportGrace', so a report that blocks, throws or never
-- returns cannot delay the exit past @bound + 'reportGrace'@. It does not wait
-- for GLFW, for termination, or for the main thread.
module Hetoimasia.GLFW.Internal.Deadline
  ( InitializationDeadline (..)
  , InitializationExpiry (..)
  , initializationTimeoutStatus
  , reportGrace
  , guardInitialization
  , guardInitializationWithin
  ) where

import Control.Concurrent (forkIO, forkIOWithUnmask)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Concurrent.STM
  ( atomically
  , check
  , newTVarIO
  , readTVar
  , registerDelay
  , writeTVar
  )
import Control.Exception (SomeException, finally, mask, throwIO, try, uninterruptibleMask_)
import Control.Monad (void, when)
import Data.Text (Text)

-- | What the application asks for: how long native initialization may take
-- before the process is ended, and what is reported when it does.
data InitializationDeadline = InitializationDeadline
  { deadlineBoundMicroseconds ∷ !Int
    -- ^ How long the guarded call may run. The application chooses it, and
    -- must choose it above every healthy initialization it measured.
  , deadlineReport ∷ !(InitializationExpiry → IO ())
    -- ^ Said once, from a thread of the guard's, before the process ends. It
    -- is the application's own bounded diagnostic and flush over its logger;
    -- the guard waits for it for at most 'reportGrace' and ignores its failure.
  }

-- | Two deadlines are equal when their bounds are: the report is an action.
instance Eq InitializationDeadline where
  a == b = deadlineBoundMicroseconds a == deadlineBoundMicroseconds b

instance Show InitializationDeadline where
  showsPrec precedence deadline =
    showParen (precedence > 10) $
      showString "InitializationDeadline {deadlineBoundMicroseconds = "
        . shows (deadlineBoundMicroseconds deadline)
        . showString ", deadlineReport = <action>}"

-- | What the report is told. It states an observed condition, never a cause:
-- initialization did not return within the bound.
data InitializationExpiry = InitializationExpiry
  { expiryBackend ∷ !Text
    -- ^ The backend whose initialization had not returned.
  , expiryBoundMicroseconds ∷ !Int
    -- ^ The bound that passed.
  , expiryStatus ∷ !Int
    -- ^ The exit status the process is about to be ended with.
  }
  deriving (Eq, Show)

-- | The exit status of a process ended by an expired initialization deadline
-- (@EX_TEMPFAIL@, 75). It is documented in @docs/run_command.md@ and differs
-- from every other status the @run@ command documents.
initializationTimeoutStatus ∷ Int
initializationTimeoutStatus = 75

-- | How long the guard waits for the report, in microseconds, after the bound
-- has passed. The process is ended when it is over, report or no report.
reportGrace ∷ Int
reportGrace = 2_000_000

data Phase = Pending | Retired | Expired
  deriving (Eq)

-- | Run the guarded native call under an optional deadline.
--
-- With no deadline the call runs as it is. With one, a timer thread is started
-- for the call; when the call returns, raises or is cancelled the thread is
-- retired, stopped and joined before the guard leaves; if the bound passes
-- first, the report runs (bounded) and the supplied exit ends the process.
--
-- The exit takes the status. It does not return in production. If it does return
-- (a CPU example's observation), the guard has still decided the call once, and
-- the call's own result or failure is then delivered after the joined thread.
guardInitialization
  ∷ (Int → IO ())
  → Text
  → Maybe InitializationDeadline
  → IO a
  → IO a
guardInitialization = guardInitializationWithin reportGrace

-- | 'guardInitialization' with the report's grace given, in microseconds: the
-- production grace is 'reportGrace', and an example that needs a report that
-- never finishes passes a short one.
guardInitializationWithin
  ∷ Int
  → (Int → IO ())
  → Text
  → Maybe InitializationDeadline
  → IO a
  → IO a
guardInitializationWithin _ _ _ Nothing call = call
guardInitializationWithin grace exit backend (Just deadline) call = mask $ \restore → do
  phase ← newTVarIO Pending
  finished ← newEmptyMVar
  -- Started masked, with the join registered in the same step as the start.
  _ ←
    forkIOWithUnmask $ \unmask →
      unmask (watch phase) `finally` putMVar finished ()
  outcome ← try @SomeException (restore call)
  settle phase finished
  either throwIO pure outcome
  where
    -- Retire the timer if it has not expired, then wait for its thread. The
    -- wait is bounded: a retired thread ends at once, and an expired one ends
    -- within 'reportGrace' (or the process ends).
    settle phase finished = uninterruptibleMask_ $ do
      atomically $ do
        current ← readTVar phase
        when (current == Pending) (writeTVar phase Retired)
      takeMVar finished

    watch phase = do
      delay ← registerDelay (deadlineBoundMicroseconds deadline)
      expired ← atomically $ do
        current ← readTVar phase
        case current of
          Pending → do
            elapsed ← readTVar delay
            check elapsed
            writeTVar phase Expired
            pure True
          _ → pure False
      when expired $ do
        reported ← newTVarIO False
        void . forkIO $ do
          _ ← try @SomeException (deadlineReport deadline expiry)
          atomically (writeTVar reported True)
        graceOver ← registerDelay grace
        atomically $ do
          done ← readTVar reported
          over ← readTVar graceOver
          check (done || over)
        exit initializationTimeoutStatus

    expiry =
      InitializationExpiry
        { expiryBackend = backend
        , expiryBoundMicroseconds = deadlineBoundMicroseconds deadline
        , expiryStatus = initializationTimeoutStatus
        }
