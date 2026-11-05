-- | A profile on an owned bound OS thread, and the order its shutdown must follow (#599), after the shipped launcher's
-- @Hetoimasia.Run.Serve@.
--
-- The native suite runs its complete Hspec profile on a bound OS thread (the /session thread/) and serves the owner loop on the
-- process main thread: window creation, surfaces and native events belong to the main thread. As in the launcher, the session
-- thread owns every scope the examples use, the texture adapter's included, and the main thread owns only the native owner and its
-- loop. The shutdown dependencies, outermost first, and what each waits for:
--
-- 1. the /profile thread's scope/ (kill and join) waits for the thread to end;
-- 2. the /host/ (the loader integration, the owner application, the owner host) tears down what the host owns, and destroys the
--    windows that are still up;
-- 3. the /texture adapter's scope/, on the session thread, drains: it waits for every texture a live window still holds to be
--    released, which happens only as the windows retire;
-- 4. the /windows/ are closed by the session thread's own example scopes, and retire only as the main thread serves the owner loop
--    (or, once it has stopped serving, as the host's teardown destroys them).
--
-- So a wait is never served by something that has stopped, on any exit. The profile thread's scope encloses the host's (1 runs after
-- 2). When the loop is left abnormally 'serveProfile' kills the session thread, by an owned second thread, which unwinds its window
-- scopes, and serves the loop again until the thread has ended, in at most 'settleAttempts' attempts, each made by the caller under a
-- /fresh supervision/ as the shipped owner drain makes it (the application's may have latched the very failure that ended the first
-- run, and the loop checks its supervision before it serves anything). A synchronous failure of an attempt starts the next one, and
-- every failure is retained beside the original, none swallowed; a cancellation delivered meanwhile is remembered, the attempt run
-- again, and the cancellation raised only after the settling, with the original failure retained beside it. If the thread has /still/
-- not ended after the last attempt the owner cannot be served any more: the failure is raised at once, without joining, and the
-- host's own teardown (2) destroys the windows the loop could not retire, so the thread's drain (3) finishes, the thread ends, and the
-- join (1) then waits for nothing. That works because the adapter's drain is on the session thread, not on the thread that raises.
--
-- State owner: the caller owns the host and what it hands the profile; the helper owns the input cell, the end cell and the
-- thread. Thread: the profile's, one bound thread, owned by 'withOwnedBoundThread' (#593) from before the host starts until after
-- it has ended; the settling kill is sent by a second owned thread because the kill waits for the profile to accept it. Lifetime:
-- the call's. Disposal: the facility's release. Nothing here sleeps.
module Test.LuaEngine.Graphics.Served
  ( Profile (..)
  , withProfileBeyond
  , serveProfile
  , settleAttempts
  ) where

import Control.Applicative ((<|>))
import Control.Concurrent (ThreadId, killThread)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, readMVar, tryReadMVar)
import Control.Exception (ExceptionWithContext (ExceptionWithContext), SomeAsyncException, SomeException, finally, fromException, mask, rethrowIO, tryWithContext)
import Data.Maybe (fromMaybe, isJust, isNothing)
import qualified Data.Text as Text
import Hetoimasia.Foundation.Resource (composeCleanup)
import Test.Support.Owned (withOwnedBoundThread, withOwnedThread)

-- | The profile thread, as the serving side sees it.
data Profile = Profile
  { profileThread ∷ !ThreadId
  , profileEnded ∷ IO Bool
    -- ^ Whether the thread has ended: a non-blocking look.
  }

-- | How many times the loop is served again before the owner is given up on (the launcher's @drainAttempts@).
settleAttempts ∷ Int
settleAttempts = 3

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
-- unmasked inside the guard that settles an abnormal exit, so a cancellation cannot arrive between the hand-over and the guard.
-- If serving is left abnormally the profile is killed and @serveFresh@, which the caller makes under a fresh supervision, is run
-- until the profile thread has ended, as described above, before the failure is raised. Both are given the predicate to stop on.
serveProfile ∷ Profile → IO () → (IO Bool → IO ()) → (IO Bool → IO ()) → IO Bool → IO ()
serveProfile profile handOver serve serveFresh finishedWork = mask $ \restore → do
  handOver
  tryWithContext @SomeException (restore (serve finishedWork)) >>= \case
    Right () → pure ()
    Left original → do
      (failures, interruption) ← settle
      -- a cancellation is raised after the settling, with the original failure beside it, never instead of it
      let (primary, retained) = case interruption of
            Just interrupted → (interrupted, ("the owner loop failure", original) : failures)
            Nothing → (original, failures)
      carried ← composeCleanup (Just primary) retained
      rethrowIO (fromMaybe primary carried)
  where
    settle = withOwnedThread (killThread (profileThread profile)) $ \_ _ → attempts (0 ∷ Int) [] Nothing
    attempts n failures interruption
      | n >= settleAttempts = pure (reverse failures, interruption)
      | otherwise =
          profileEnded profile >>= \ended →
            if ended
              then pure (reverse failures, interruption)
              else
                attempt interruption >>= \case
                  (Nothing, interrupted) → attempts (n + 1) failures interrupted
                  (Just failure, interrupted) → attempts (n + 1) ((Text.pack ("the settling attempt " <> show (n + 1)), failure) : failures) interrupted
    -- One attempt. A cancellation delivered meanwhile is remembered, the first one kept, and the attempt run again.
    attempt interruption =
      tryWithContext @SomeException (serveFresh (profileEnded profile)) >>= \case
        Right () → pure (Nothing, interruption)
        Left failure
          | isAsynchronous failure → attempt (interruption <|> Just failure)
          | otherwise → pure (Just failure, interruption)
    isAsynchronous (ExceptionWithContext _ raised) = not (isNothing (fromException raised ∷ Maybe SomeAsyncException))
