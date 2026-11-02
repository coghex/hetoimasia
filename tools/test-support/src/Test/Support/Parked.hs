-- | Run a worker, park it where a cancellation is to land, cancel it there, let it go on and answer how it ended (#584).
--
-- This is the orchestration the native suite's child helper examples use to deliver a cancellation into a release: the
-- worker runs the action it is given on a thread of its own and calls the /park/ it is handed at the point to be cancelled
-- at; the park says it has been reached, once, and waits at a gate. The orchestration then throws 'UserInterrupt' at the
-- worker there, opens the gate and waits for the worker to finish. Explicit synchronization throughout, every wait bounded
-- by a bound the caller states: a worker that never reaches its park (or never finishes) fails the example instead of
-- hanging it.
--
-- /Ownership./ The worker is owned ('Test.Support.Owned.withOwnedThread'): however the example ends, a failed wait, a
-- returned answer or a cancellation of the example itself, the worker has ended and been joined, and so has whatever the
-- action's own unwinding releases (a child process it owns), before 'parkedRelease' returns or raises. The gate is the one
-- thing the worker may be held at, so the scope opens it, idempotently, in the release and before the join
-- ('withOwnedThreadOpening', registered in the step that starts the worker): a release that remembers a cancellation retries
-- its park, and a worker killed while the gate is closed would hold the join for ever, including when the example is
-- cancelled as the scope begins, before any handler of the body could have been installed.
--
-- State owner: this function. Readers/writers: the worker (the park, the finish cell), the example thread (the waits, the
-- gate). Thread: one worker per call. Lifetime: the call. Disposal: the call's scope. Nothing sleeps; @base@, @stm@ and
-- @hspec@ only.
module Test.Support.Parked
  ( ParkBounds (..)
  , defaultParkBounds
  , parkedRelease
  ) where

import Control.Concurrent (throwTo)
import Control.Concurrent.MVar (newEmptyMVar, readMVar, tryPutMVar)
import Control.Concurrent.STM (atomically, newEmptyTMVarIO, orElse, putTMVar, readTMVar, tryPutTMVar)
import Control.Exception (AsyncException (UserInterrupt), ExceptionWithContext, SomeException, tryWithContext)
import Control.Monad (void)
import System.Timeout (timeout)
import Test.Hspec (expectationFailure)
import Test.Support.Owned (withOwnedThreadOpening)

-- | How long, in microseconds, the orchestration waits for the worker to reach its park (or end), and then to finish once it
-- has been let go. A bound expires only when the worker is stuck; an example that wants a failure branch states a bound of
-- zero, which expires at once and needs no timing.
data ParkBounds = ParkBounds
  { boundReach ∷ !Int
  , boundFinish ∷ !Int
  }

-- | Thirty seconds each: long enough to bound a stuck worker, never long enough to matter otherwise.
defaultParkBounds ∷ ParkBounds
defaultParkBounds = ParkBounds (30 * 1000000) (30 * 1000000)

-- | Run the worker (given its park) on an owned thread, wait until it has parked (or ended), throw 'UserInterrupt' at it
-- there, open the gate and answer how the worker ended. A worker that ended without reaching its park, one that did not
-- reach it within the bound, and one that did not finish within the bound fail the example, and in each case the worker has
-- ended and been joined when the failure is raised.
parkedRelease ∷ ParkBounds → (IO () → IO ()) → IO (Either (ExceptionWithContext SomeException) ())
parkedRelease bounds worker = do
  parked ← newEmptyTMVarIO
  gate ← newEmptyMVar
  finished ← newEmptyTMVarIO
  let park = atomically (void (tryPutTMVar parked ())) >> readMVar gate
      open = void (tryPutMVar gate ())
  withOwnedThreadOpening open (tryWithContext @SomeException (worker park) >>= atomically . putTMVar finished) $ \thread _ → do
        reached ← timeout (boundReach bounds) (atomically ((Left <$> readTMVar parked) `orElse` (Right <$> readTMVar finished)))
        case reached of
          Just (Left ()) → pure ()
          Just (Right _) → expectationFailure "the helper ended without reaching its release"
          Nothing → expectationFailure ("the helper did not reach its release within " <> seconds (boundReach bounds))
        throwTo thread UserInterrupt
        open
        timeout (boundFinish bounds) (atomically (readTMVar finished))
          >>= maybe (expectationFailure ("the helper did not finish within " <> seconds (boundFinish bounds)) >> ioError (userError "unreachable")) pure
  where
    seconds microseconds = show (microseconds `div` 1000000) <> " seconds"
