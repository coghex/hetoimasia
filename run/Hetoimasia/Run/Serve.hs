-- | Serving the native owner's loop on the process main thread while the session runs on a thread of its own, and
-- unwinding them together when the loop fails. It names nothing native: the owner is a record of the three things
-- it needs, so the shutdown rules are examined without a device or a window.
--
-- = The rules
--
-- * The session thread is created in the same masked step that installs the guard that stops and joins it, so a
--   cancellation can never leave it running with nothing to end it.
-- * When the loop ends because the session ended, the session's own result (or failure, with its context) is the
--   answer.
-- * When the loop /fails/ (or the main thread is cancelled in it), the session is asked to stop and the owner is
--   served again by a /drain/ loop until the session has settled, because the session's cleanup closes windows
--   and waits for their native destruction, which only this thread's loop performs; joining it without serving
--   would deadlock. The drain is independent of the supervision checkpoints that already failed (the owner
--   makes its own). A drain that itself fails is logged and run again, a bounded number of times: an owner that
--   cannot be served any more is a failed owner, which the session's providers see and retire as failed. A
--   cancellation during any of this is remembered and raised after the join, never instead of it.
-- * The loop's failure stays primary and is raised with its context once the session has settled; the session's
--   own failure, whatever its cleanup raised, is retained beside it.
module Hetoimasia.Run.Serve
  ( Owner (..)
  , serve
  , drainAttempts
  ) where

import Control.Concurrent (forkIOWithUnmask)
import Control.Concurrent.MVar (MVar, newEmptyMVar, putMVar, readMVar, tryReadMVar)
import Control.Exception (ExceptionWithContext, SomeException, displayException, mask, rethrowIO, tryWithContext)
import Control.Monad (unless, void)
import Data.Maybe (isJust)
import qualified Data.Text as Text
import Hetoimasia.Foundation.Log (Component, Logger, logError, unsafeComponent)
import Hetoimasia.Run.Output (reportText)
import Hetoimasia.Run.Settle (attemptSync, bestEffort, combine, remembering)

-- | What the main thread serves.
data Owner = Owner
  { ownerServe ∷ IO () → IO Bool → IO ()
  -- ^ Run the owner's loop on this thread: do the first action on every turn, and finish when the second answers
  -- True. A failure of the loop, or of a turn's action, ends it and propagates.
  , ownerDrain ∷ IO Bool → IO ()
  -- ^ Run a loop that does nothing but serve the owner's retirement until the action answers True, independent of
  -- the supervision checkpoints the ordinary loop has already failed.
  , ownerWake ∷ IO ()
  -- ^ Wake the loop so it sees that the session has ended.
  }

component ∷ Component
component = unsafeComponent "run.serve"

-- | How many times a failing drain is run again before the join is left to the session alone.
drainAttempts ∷ Int
drainAttempts = 3

-- | Run the session on a thread of its own and serve the owner on this one until it has ended.
serve ∷ ∀ a. Logger → Owner → IO () → IO () → IO a → IO a
serve logger owner stopSession turn session = mask $ \restore → do
  done ← newEmptyMVar ∷ IO (MVar (Either (ExceptionWithContext SomeException) a))
  -- The session thread exists from here on, so everything below is inside the guard that stops and joins it.
  _ ← forkIOWithUnmask $ \unmask → do
    result ← unmask (tryWithContext session)
    putMVar done result
    ownerWake owner
  let over = isJust <$> tryReadMVar done
  tryWithContext (restore (ownerServe owner turn over)) >>= \case
    Right () → pure ()
    Left failure → do
      stopSession
      remembering (drain over)
      remembering (void (readMVar done))
      settled ← readMVar done
      rethrowIO =<< case settled of
        Left sessionFailure → combine failure [("the session, which had to unwind after the owner loop failed", sessionFailure)]
        Right _ → pure failure
  remembering (void (readMVar done))
  readMVar done >>= either rethrowIO pure
  where
    drain over = go 0
      where
        go attempt
          | attempt >= drainAttempts = pure ()
          | otherwise =
              over >>= \finished →
                unless finished $
                  attemptSync (ownerDrain owner over) >>= \case
                    Right () → pure ()
                    Left again → do
                      bestEffort (logError logger component "the owner loop failed while the session was draining" [("reason", reportText (Text.pack (displayException again)))])
                      go (attempt + 1 ∷ Int)
