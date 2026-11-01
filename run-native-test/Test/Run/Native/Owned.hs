-- | The one way a test-side helper thread is started in this suite (LFE-25, #540): owned, so that however the scope that
-- needed it ends, the thread has ended and been joined before the scope returns.
--
-- * /Acquisition/ is one masked step: the thread is forked and the stop-and-join is registered before any asynchronous
--   exception can be delivered, so a cancellation cannot land between the two and abandon the thread.
-- * /The body/ runs with the caller's interruptibility restored.
-- * /Release/ is not interruptible: it delivers a kill to the thread (which does nothing to one that has already ended) and
--   waits for the thread's end, on a normal return, an exception, a timeout of the example or a cancellation alike. The
--   thread's end is announced however it ended, by the same step that started it.
--
-- A helper that must be let go before it can end (a gate it waits at) is opened by the caller in a @finally@ inside the
-- body, which runs before this release does.
module Test.Run.Native.Owned
  ( withOwnedThread
  ) where

import Control.Concurrent (ThreadId, forkIOWithUnmask, killThread)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, readMVar)
import Control.Exception (finally, mask, uninterruptibleMask_)

-- | Run the action on a thread of its own for the length of the body, which is given the thread and a wait for its end.
withOwnedThread ∷ IO () → (ThreadId → IO () → IO a) → IO a
withOwnedThread action body = mask $ \restore → do
  done ← newEmptyMVar
  thread ← forkIOWithUnmask $ \unmask → unmask action `finally` putMVar done ()
  restore (body thread (readMVar done)) `finally` uninterruptibleMask_ (killThread thread >> readMVar done)
