-- | What the native suite's ownership regressions share (#594): the deliberately unowned start their negative controls compare
-- each converted helper with, and the ways the scope that owns a helper's thread is made to end.
--
-- Each regression runs one scenario twice with the same judgement, once through the facility ('ownedScope') and once through an
-- unowned start ('unownedScope', the start the helper made before it was converted): the judgement must hold for the first and
-- fail for the second, so a regression that could not tell an owned start from an unowned one cannot pass. A control records its
-- failed judgement first and then stops and joins everything it left, even if an assertion failed ('runCleanups'), so it leaves
-- nothing for a later example. The same pattern as the root suite's, which this suite cannot import (another suite's modules).
--
-- State owner: each scenario owns its 'Cleanups'. Thread: the unowned start's, one per call. Lifetime: the scenario's.
-- Disposal: 'runCleanups', which the control runs on every way out; the owned scope disposes of its thread itself. Nothing here
-- sleeps: every wait is a gate, an MVar or the runtime's report of what a thread is blocked on, and the bound a scenario runs
-- under exists only to keep a stuck example from hanging the run.
module Test.GLFW.Native.Unowned
  ( -- * The unowned start
    Cleanups
  , newCleanups
  , cleanupLater
  , runCleanups
  , unownedScope

    -- * Ending a scope
  , Ending (..)
  , endings
  , Boom (..)
  , endBody
  , endedFromOutside
  , endedAs

    -- * Judging a thread
  , hasEnded
  ) where

import Control.Concurrent (ThreadId, forkIOWithUnmask, forkOS, killThread, myThreadId, throwTo, yield)
import Control.Concurrent.MVar (MVar, newEmptyMVar, putMVar, readMVar, tryPutMVar)
import Control.Exception (AsyncException (UserInterrupt), Exception, SomeException, finally, fromException, mask_, throwIO, toException, try, uninterruptibleMask_)
import Control.Monad (void)
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import GHC.Conc (ThreadStatus (ThreadBlocked, ThreadDied, ThreadFinished), threadStatus)
import GHC.IO (unsafeUnmask)
import Test.GLFW.Native.Threads (Boundness (..), Scope (..))
import Test.Support.Cancel (withCancellationAfter)
import Test.Support.Owned (withOwnedThread)

-- | What an unowned control must stop and join by itself afterwards, newest first.
newtype Cleanups = Cleanups (IORef [IO ()])

newCleanups ∷ IO Cleanups
newCleanups = Cleanups <$> newIORef []

-- | Register something to do once the control has recorded its judgement; the newest runs first. A gate a parked thread waits
-- at is registered here too, which also keeps that gate reachable for as long as the control runs, so the runtime does not end
-- the thread waiting at it as deadlocked before the control has judged it.
cleanupLater ∷ Cleanups → IO () → IO ()
cleanupLater (Cleanups ref) cleanup = atomicModifyIORef' ref (\held → (cleanup : held, ()))

-- | Run every registered cleanup, the newest first, each even if an earlier one failed.
runCleanups ∷ Cleanups → IO ()
runCleanups (Cleanups ref) = readIORef ref >>= foldr (\cleanup rest → cleanup `finally` rest) (pure ())

-- | A deliberately unowned start of either boundness, the controls' only one: the thread is started and its end announced
-- however it ended, and nothing stops or joins it when the scope ends. Its independent stop-and-join is registered with the
-- control in the same masked step, so the control can always end what it left, even a thread it kills before it ran anything.
-- The defect the controls model is the missing stop-and-join of the scope, not an unannounced end.
unownedScope ∷ Cleanups → Scope
unownedScope cleanups = Scope $ \boundness open action body → do
  (thread, done) ← startUnowned cleanups boundness open action
  body thread (readMVar done)

startUnowned ∷ Cleanups → Boundness → IO () → IO () → IO (ThreadId, MVar ())
startUnowned cleanups boundness open action = mask_ $ do
  done ← newEmptyMVar
  thread ← case boundness of
    Unbound → forkIOWithUnmask $ \unmask → unmask action `finally` putMVar done ()
    Bound → uninterruptibleMask_ (forkOS (unsafeUnmask action `finally` putMVar done ()))
  cleanupLater cleanups (open >> killThread thread >> readMVar done)
  pure (thread, done)

-- | How the scope that owns a helper is made to end while the helper's thread is parked: its body fails, or it is cancelled.
data Ending = Raises | Cancelled
  deriving (Eq, Show)

endings ∷ [(String, Ending)]
endings =
  [ ("the example fails", Raises)
  , ("the example is cancelled", Cancelled)
  ]

-- | The failure an example raises, told apart from every other.
data Boom = Boom
  deriving (Eq, Show)

instance Exception Boom

-- | The end of a scope that has a body, run in that body once the thread is parked: the body fails, or the example is
-- cancelled there by a helper thread the scope owns, and the body then waits where only the cancellation can reach it.
endBody ∷ Ending → IO () → IO ()
endBody Raises parked = parked >> throwIO Boom
endBody Cancelled parked = withCancellationAfter parked (pure ()) holdUntilCancelled

-- | The end of a scope that has no body of its own (a helper that starts a thread and waits for it): the exception that ends it
-- is delivered to the waiting caller from outside, once the thread is parked, by a helper the call owns. The action is expected
-- to be ended by it, and its outcome is returned for 'endedAs' to judge.
endedFromOutside ∷ Ending → IO () → IO a → IO (Either SomeException a)
endedFromOutside ending parked action = do
  caller ← myThreadId
  withOwnedThread (parked >> mask_ (throwTo caller (exceptionFor ending))) $ \_ _ → try action
  where
    exceptionFor Raises = toException Boom
    exceptionFor Cancelled = toException UserInterrupt

-- | Whether an example ended the way the ending says.
endedAs ∷ Ending → Either SomeException a → Bool
endedAs Raises = either ((== Just Boom) . fromException) (const False)
endedAs Cancelled = either ((== Just UserInterrupt) . fromException) (const False)

-- | Wait where only the example's own end can reach it. The wait is bounded by the caller's bound, and keeps the waiting
-- thread reachable so the runtime does not end it as deadlocked.
holdUntilCancelled ∷ IO ()
holdUntilCancelled = newEmptyMVar >>= \hold → readMVar hold `finally` void (tryPutMVar hold ())

-- | The judgement the facility makes true: the thread has ended, and been joined, when the scope returns. A thread that is
-- blocked has not ended; one that ended is finished, or is running its last steps after announcing its end, which the poll
-- yields to (a count of yields, never a duration, so a thread that never ends gives up the same way on any machine).
hasEnded ∷ ThreadId → IO Bool
hasEnded thread = go (100000 ∷ Int)
  where
    go 0 = pure False
    go remaining =
      threadStatus thread >>= \case
        ThreadFinished → pure True
        ThreadDied → pure True
        ThreadBlocked _ → pure False
        _ → yield >> go (remaining - 1)
