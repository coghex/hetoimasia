-- | A profile on an owned bound OS thread while the calling thread serves what the profile needs (#599).
--
-- The native suite runs its complete Hspec profile on a bound OS thread and serves the owner loop on the process main thread:
-- window creation, surfaces and native events belong to the main thread, and the examples' window scopes close and drain only
-- as the loop services their commands. That makes the loop a supplier of the profile's own teardown, so the loop's scope
-- must outlive the profile thread's end: when the loop is left abnormally (a failure, a cancellation) the profile thread is
-- told to end and the loop is served again until the thread has ended, and only then does the facility's uninterruptible join
-- run. Otherwise the join would wait for a thread that is waiting for a main thread that has stopped serving.
--
-- State owner: the profile thread owns its work and the @ended@ cell the helper announces its end in; the caller owns what
-- @serve@ drives. Thread: the profile's, one bound thread, owned by 'withOwnedBoundThread' (#593); the settling kill is sent by
-- a second owned thread, because the kill waits for the profile to accept it and the profile may be inside a drain that only
-- serving ends. Lifetime: the call's. Disposal: the facility's release. Nothing here sleeps.
module Test.LuaEngine.Graphics.Served
  ( withServedBoundThread
  ) where

import Control.Concurrent (killThread)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, tryReadMVar)
import Control.Exception (SomeAsyncException, SomeException, catch, finally, fromException, mask, onException, throwIO)
import Data.Maybe (isJust, isNothing)
import Test.Support.Owned (withOwnedBoundThread, withOwnedThread)

-- | Run the profile on an owned bound thread, and serve with @serve@ on the calling thread. The first predicate answers whether
-- the profile has produced its result (the normal reason to stop serving); @serve@ is given the predicate to stop on and
-- returns when it holds. If @serve@ is left abnormally the profile thread is killed and @serve@ is run again, with the predicate
-- "the thread has ended", before the exception continues; a second failure of @serve@ is not masked, but is not allowed to
-- skip the join either.
withServedBoundThread ∷ IO () → IO Bool → (IO Bool → IO ()) → IO ()
withServedBoundThread profile finishedWork serve = mask $ \restore → do
  ended ← newEmptyMVar
  withOwnedBoundThread (profile `finally` putMVar ended ()) $ \thread _ → do
    let over = isJust <$> tryReadMVar ended
        -- A failure of the settling run is the original one's to report, but a cancellation of it is never swallowed.
        settle = withOwnedThread (killThread thread) $ \_ _ →
          serve over `catch` \failure →
            if isNothing (fromException failure ∷ Maybe SomeAsyncException) then pure () else throwIO (failure ∷ SomeException)
    -- The facility enters its body with the interruptibility it was called with, which here is masked: the handler is installed
    -- before any cancellation can be delivered, and serving is the one thing run unmasked, inside it. A cancellation delivered
    -- as the body begins would otherwise arrive before the handler and go to the facility's join, which waits for a thread
    -- that needs the loop served.
    restore (serve finishedWork) `onException` settle
