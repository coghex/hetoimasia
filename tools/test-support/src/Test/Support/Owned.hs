-- | The one way a test-side helper thread is started (LFE-25, #540; #584): owned, so that however the scope that needed it
-- ends, the thread has ended and been joined before the scope returns.
--
-- * /Acquisition/ is one masked step: the thread is forked and the stop-and-join is registered before any asynchronous
--   exception can be delivered, so a cancellation cannot land between the two and abandon the thread.
-- * /The body/ runs with the caller's interruptibility restored.
-- * /Release/ is not interruptible: it delivers a kill to the thread (which does nothing to one that has already ended) and
--   waits for the thread's end, on a normal return, an exception, a timeout of the example or a cancellation alike. The
--   thread's end is announced however it ended, by the same step that started it.
--
-- A helper that must be let go before it can end (a gate it waits at, whose release is retried after a kill) is let go by
-- 'withOwnedThreadOpening', which registers the opening in the same masked step as the start and runs it first in the
-- release. It cannot be a @finally@ inside the body: a cancellation delivered as the body begins would arrive before that
-- @finally@ is installed, and the release waits without an interrupt for the thread's end, so a gate left closed would hang
-- the join. The opening is idempotent ('Control.Concurrent.MVar.tryPutMVar') and does not block.
--
-- It uses no timed wait and depends on @base@ alone, so any suite may use it.
module Test.Support.Owned
  ( withOwnedThread
  , withOwnedThreadOpening
  ) where

import Control.Concurrent (ThreadId, forkIOWithUnmask, killThread)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, readMVar)
import Control.Exception (finally, mask, uninterruptibleMask_)

-- | Run the action on a thread of its own for the length of the body, which is given the thread and a wait for its end.
-- The wait may be repeated, and may be made after the thread has ended on its own.
withOwnedThread ∷ IO () → (ThreadId → IO () → IO a) → IO a
withOwnedThread = withOwnedThreadOpening (pure ())

-- | 'withOwnedThread' for a thread that may be held at something only the scope can open: the first argument is run, in the
-- uninterruptible release and before the kill, however the scope ended. It must not block and must be safe to run when what it
-- opens is already open (and when the thread never ran).
withOwnedThreadOpening ∷ IO () → IO () → (ThreadId → IO () → IO a) → IO a
withOwnedThreadOpening open action body = mask $ \restore → do
  done ← newEmptyMVar
  thread ← forkIOWithUnmask $ \unmask → unmask action `finally` putMVar done ()
  restore (body thread (readMVar done)) `finally` uninterruptibleMask_ (open >> killThread thread >> readMVar done)
