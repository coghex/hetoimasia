-- | What the sample's ownership regressions share (#600): the scope the regressions run a helper thread in, the
-- deliberately unowned start their negative controls compare it with, and the ways the example that owns the scope ends.
--
-- Each regression runs one scenario twice with the same judgement, once through the facility ('ownedScope', which is
-- "Test.Support.Owned") and once through an unowned start ('unownedScope', the start the converted sites made before they
-- were owned): the judgement must hold for the first and fail for the second, so a regression that could not tell an owned
-- start from an unowned one cannot pass. A control records its failed judgement first and then stops and joins everything it
-- left, even if an assertion failed ('runCleanups'), so it leaves nothing for a later example.
--
-- State owner: each scenario owns its 'Cleanups'. Thread: the unowned start's, one per call. Lifetime: the scenario's.
-- Disposal: 'runCleanups', which the control runs on every way out; the owned scope disposes of its thread itself. Nothing
-- here sleeps: every wait is a gate, an MVar or the runtime's report of what a thread is blocked on, and a bound exists only
-- to keep a stuck example from hanging the run.
module Test.Domains.Unowned
  ( -- * Scopes
    Scope
  , ownedScope
  , unownedScope
    -- * Controls
  , Cleanups
  , newCleanups
  , cleanupLater
  , runCleanups
    -- * Ending a scope
  , Ending (..)
  , endings
  , runEnding
    -- * Judging a thread
  , hasEnded
  , holdUntilCancelled
  ) where

import Control.Concurrent (ThreadId, forkIOWithUnmask, killThread, yield)
import Control.Concurrent.MVar (MVar, newEmptyMVar, putMVar, readMVar, tryPutMVar)
import Control.Exception (AsyncException (UserInterrupt), Exception, finally, mask_, throwIO, try)
import Control.Monad (void)
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import GHC.Conc (ThreadStatus (ThreadBlocked, ThreadDied, ThreadFinished), threadStatus)
import Test.Hspec (shouldBe)
import Test.Support.Bounded (bounded)
import Test.Support.Cancel (withCancellationAfter)
import Test.Support.Owned (withOwnedThreadOpening)

-- | A way to start a thread for the length of a body: the facility, or the unowned start a control compares it with. The
-- first argument is what must be let go before the thread can end (a gate it waits at, opened idempotently and without
-- blocking); the owned scope runs it in its uninterruptible release, and the control's cleanup runs it before it kills.
type Scope = IO () → IO () → (ThreadId → IO () → IO ()) → IO ()

-- | The facility itself.
ownedScope ∷ Scope
ownedScope = withOwnedThreadOpening

-- | What an unowned control must stop and join by itself afterwards, newest first.
newtype Cleanups = Cleanups (IORef [IO ()])

newCleanups ∷ IO Cleanups
newCleanups = Cleanups <$> newIORef []

-- | Register something to do once the control has recorded its judgement; the newest runs first.
cleanupLater ∷ Cleanups → IO () → IO ()
cleanupLater (Cleanups ref) cleanup = atomicModifyIORef' ref (\held → (cleanup : held, ()))

-- | Run every registered cleanup, the newest first, each even if an earlier one failed.
runCleanups ∷ Cleanups → IO ()
runCleanups (Cleanups ref) = readIORef ref >>= foldr (\cleanup rest → cleanup `finally` rest) (pure ())

-- | A deliberately unowned start, the controls' only one: the thread is started and its end announced however it ended, and
-- nothing stops or joins it when the scope ends. Its independent stop-and-join is registered with the control in the same
-- masked step, so the control can always end what it left, even a thread it kills before it ran anything. The defect the
-- controls model is the missing stop-and-join of the scope, not an unannounced end.
unownedScope ∷ Cleanups → Scope
unownedScope cleanups open action body = do
  (thread, done) ← startUnowned cleanups open action
  body thread (readMVar done)

startUnowned ∷ Cleanups → IO () → IO () → IO (ThreadId, MVar ())
startUnowned cleanups open action = mask_ $ do
  done ← newEmptyMVar
  thread ← forkIOWithUnmask $ \unmask → unmask action `finally` putMVar done ()
  cleanupLater cleanups (open >> killThread thread >> readMVar done)
  pure (thread, done)

-- | How the example that owns a scope is made to end while the scope's threads are parked.
data Ending = Raises | Cancelled
  deriving (Eq, Show)

-- | The failure an example raises from its body, told apart from every other.
data Boom = Boom
  deriving (Eq, Show)

instance Exception Boom

endings ∷ [(String, Ending)]
endings =
  [ ("the example fails", Raises)
  , ("the example is cancelled", Cancelled)
  ]

-- | Run a scenario that ends the way the ending says, and check that it ended that way. The scenario is given the end it
-- takes once its threads are parked: it runs that, in its innermost scope's body, with a wait for the point at which the
-- threads are parked.
runEnding ∷ Ending → ((IO () → IO ()) → IO ()) → IO ()
runEnding ending scenario = case ending of
  Raises →
    try @Boom (bounded (scenario (\parked → parked >> throwIO Boom))) >>= (`shouldBe` Left Boom)
  Cancelled →
    try @AsyncException (bounded (scenario (\parked → withCancellationAfter parked (pure ()) holdUntilCancelled)))
      >>= (`shouldBe` Left UserInterrupt)

-- | Wait where only the example's own end can reach it. The wait is bounded by the caller's 'bounded', and keeps the waiting
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
