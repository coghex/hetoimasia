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
-- /Bound threads (#593)./ A test that asserts boundness (a seam that rejects entry from a bound worker and from an unbound one,
-- a thread designated as the process main thread) needs an OS-bound thread, and 'withOwnedBoundThread' starts one with the same
-- ownership properties: the thread is bound ('Control.Concurrent.isCurrentThreadBound' is true on it) and there is no unowned
-- start to reach for. The one difference from 'withOwnedThread' is the acquisition. @forkOS@ blocks its caller until the new OS
-- thread has reported its 'ThreadId', and that wait is interruptible even under @mask@, so a cancellation delivered inside it
-- would abandon a thread that already exists. The start is therefore made in an uninterruptible step: the wait is for the
-- operating system to run a thread that waits for nothing the example controls, so it is short and cannot depend on the
-- example. The thread itself starts with exceptions masked and unmasks only inside the announcing @finally@, exactly as the
-- unbound start does, so a kill can never find it unprotected. The start is generic: it designates nothing and knows nothing of
-- any native library; a test that must also designate the thread (GLFW's process main thread) does so as the first step of the
-- action it passes.
--
-- /Pinned to a capability (#610)./ 'withOwnedThreadOn' and 'withOwnedThreadOpeningOn' are the same ownership for a thread that
-- is pinned to one capability ('Control.Concurrent.forkOn'). An example whose point is that a cancellation is /pending/ against
-- a thread before that thread's next effect starts both its target and the cancellation's sender this way, on the same
-- capability. On one capability @throwTo@ to a masked thread is settled where it is made: the exception is on the target's
-- queue before the sender is recorded as blocked delivering, so a sender seen in @BlockedOnException@ has an exception pending
-- against the target, always. Across capabilities @throwTo@ is a message the target's capability takes in only when it next
-- looks at its inbox (GHC 9.14.1 @rts/Schedule.c@, @scheduleProcessInbox@, which takes the capability's lock with a try-acquire
-- and returns at once when the lock is busy), so no wait on the sender's status, however long, establishes that the target has
-- received the exception: the sender reports blocked when it has /sent/ it. The pin removes the distinction instead of racing
-- with it. A capability number is taken modulo the number of capabilities, as 'forkOn' takes it.
--
-- It uses no timed wait and depends on @base@ alone, so any suite may use it.
module Test.Support.Owned
  ( withOwnedThread
  , withOwnedThreadOpening
  , withOwnedBoundThread
  , withOwnedBoundThreadOpening
  , withOwnedThreadOn
  , withOwnedThreadOpeningOn
  ) where

import Control.Concurrent (ThreadId, forkIOWithUnmask, forkOS, forkOn, killThread)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, readMVar)
import Control.Exception (finally, mask, uninterruptibleMask_)
import GHC.IO (unsafeUnmask)

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

-- | 'withOwnedThread' for an OS-bound thread: the action runs on a thread for which @isCurrentThreadBound@ holds, and the scope
-- stops and joins it on every way out, a cancellation delivered while the thread is starting included.
withOwnedBoundThread ∷ IO () → (ThreadId → IO () → IO a) → IO a
withOwnedBoundThread = withOwnedBoundThreadOpening (pure ())

-- | 'withOwnedThreadOpening' for an OS-bound thread; see the module header for why the start is uninterruptible.
withOwnedBoundThreadOpening ∷ IO () → IO () → (ThreadId → IO () → IO a) → IO a
withOwnedBoundThreadOpening open action body = mask $ \restore → do
  done ← newEmptyMVar
  -- The same unmasking as 'forkIOWithUnmask' gives: the thread inherits the start's uninterruptible state and unmasks only the action.
  thread ← uninterruptibleMask_ (forkOS (unsafeUnmask action `finally` putMVar done ()))
  restore (body thread (readMVar done)) `finally` uninterruptibleMask_ (open >> killThread thread >> readMVar done)

-- | 'withOwnedThread' for a thread pinned to the given capability (see "Test.Support.Owned" for why an example pins).
withOwnedThreadOn ∷ Int → IO () → (ThreadId → IO () → IO a) → IO a
withOwnedThreadOn capability = withOwnedThreadOpeningOn capability (pure ())

-- | 'withOwnedThreadOpening' for a thread pinned to the given capability: the same single masked acquisition (start and
-- registered stop-and-join), the same opening run first in the uninterruptible release, and the thread's action runs
-- unmasked, as it does for an unpinned start.
withOwnedThreadOpeningOn ∷ Int → IO () → IO () → (ThreadId → IO () → IO a) → IO a
withOwnedThreadOpeningOn capability open action body = mask $ \restore → do
  done ← newEmptyMVar
  thread ← forkOn capability $ unsafeUnmask action `finally` putMVar done ()
  restore (body thread (readMVar done)) `finally` uninterruptibleMask_ (open >> killThread thread >> readMVar done)
