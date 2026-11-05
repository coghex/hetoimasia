-- | A profile on an owned bound OS thread, and the order its shutdown must follow (#599).
--
-- The native suite runs its complete Hspec profile on a bound OS thread and serves the owner loop on the process main thread:
-- window creation, surfaces and native events belong to the main thread, and the examples' window scopes close and drain only
-- as the main thread services their commands. The shutdown dependencies, outermost first, and what each waits for:
--
-- 1. the /profile thread's scope/ (kill and join) waits for the thread to end;
-- 2. the /host/ (the loader integration, the owner application, the owner host) tears down what the host owns;
-- 3. the /texture backend's scope/ (@withTextureGraphics@, inside the host's body) drains: it waits for every texture a live
--    window still holds to be released, which happens only as the windows retire;
-- 4. the /windows/ are closed by the profile thread's own example scopes, and retire only as the main thread serves the owner
--    loop.
--
-- So a wait is never served by something that has stopped: the profile thread's scope encloses the host's (1 runs after 2), so
-- the host's own teardown can retire what the profile still holds; and the one thing that must still run when the loop is left
-- abnormally, before the texture backend's drain (3) begins, is the loop itself, serving the windows' retirement ('serveProfile'):
-- the profile thread is killed by a second owned thread, which unwinds its window scopes, and the loop is served again until the
-- thread has ended. A latched failure that makes serving the loop again impossible is the one case that cannot be answered from
-- here (the windows can never retire); the failure of the second serving is reported as the original failure's companion and
-- not masked, but it is not made to hang the run by the helper either.
--
-- State owner: the caller owns the host and what it hands the profile; the helper owns the input cell, the end cell and the
-- thread. Thread: the profile's, one bound thread, owned by 'withOwnedBoundThread' (#593) from before the host starts until after
-- it has ended; the settling kill is sent by a second owned thread because the kill waits for the profile to accept it. Lifetime:
-- the call's. Disposal: the facility's release. Nothing here sleeps.
module Test.LuaEngine.Graphics.Served
  ( Profile (..)
  , withProfileBeyond
  , serveProfile
  ) where

import Control.Concurrent (ThreadId, killThread)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, readMVar, tryReadMVar)
import Control.Exception (SomeAsyncException, SomeException, catch, finally, fromException, mask, onException, throwIO)
import Data.Maybe (isJust, isNothing)
import Test.Support.Owned (withOwnedBoundThread, withOwnedThread)

-- | The profile thread, as the serving side sees it.
data Profile = Profile
  { profileThread ∷ !ThreadId
  , profileEnded ∷ IO Bool
    -- ^ Whether the thread has ended: a non-blocking look.
  }

-- | Start the profile on an owned bound thread, where it waits for its input, and run the host scope, which is handed the
-- function that gives the profile its input and the profile itself. The thread is killed and joined when the host scope has
-- ended however it ended, including when it ended before the input was handed over.
withProfileBeyond ∷ (a → IO ()) → ((a → IO ()) → Profile → IO r) → IO r
withProfileBeyond profile hostScope = do
  input ← newEmptyMVar
  ended ← newEmptyMVar
  withOwnedBoundThread ((readMVar input >>= profile) `finally` putMVar ended ()) $ \thread _ →
    hostScope (putMVar input) (Profile thread (isJust <$> tryReadMVar ended))

-- | Give the profile its input and serve until it has its result (the predicate @finishedWork@), as one step: serving is run
-- unmasked inside the handler that settles an abnormal exit, so a cancellation cannot arrive between the hand-over and the
-- handler. If serving is left abnormally the profile is killed by an owned second thread and @serve@ is run again, until the
-- profile thread has ended, before the exception continues. @serve@ is given the predicate to stop on.
serveProfile ∷ Profile → IO () → (IO Bool → IO ()) → IO Bool → IO ()
serveProfile profile handOver serve finishedWork = mask $ \restore → do
  handOver
  restore (serve finishedWork) `onException` settle
  where
    -- A failure of the settling run is the original one's to report, but a cancellation of it is never swallowed.
    settle = withOwnedThread (killThread (profileThread profile)) $ \_ _ →
      serve (profileEnded profile) `catch` \failure →
        if isNothing (fromException failure ∷ Maybe SomeAsyncException) then pure () else throwIO (failure ∷ SomeException)
