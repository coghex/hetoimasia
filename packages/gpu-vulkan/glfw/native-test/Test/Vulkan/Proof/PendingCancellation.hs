-- | A worker that is cancelled for real at a moment its own code chooses, and the owned threads that make that deterministic
-- (#596).
--
-- The headless proof examples ("Test.Vulkan.Proof.ConstructionSpec", "Test.Vulkan.Proof.PublicationSpec") ask where a
-- cancellation lands when it is /certainly pending/ against code that has not yet restored its caller's masking state. The
-- code under test runs on a worker; a stand-in inside it calls the /arm/ this module hands it, which returns once a
-- cancellation of the worker is certainly pending, without delivering it and without waiting anywhere it could be delivered.
-- Where it is then taken is decided by the code under test, which is the point of the examples.
--
-- /Why both threads are pinned./ 'throwTo' between two threads on one capability is settled where it is made: when the target
-- is masked, the exception is on its queue before the sender is recorded as blocked delivering. Across capabilities it is a
-- message the target's capability takes in later, and the sender is recorded as blocked from the moment it sends one, a state
-- that must not be mistaken for "pending against the target". Pinning the worker and the killer to one capability removes the
-- distinction instead of racing with it, so the examples read the same under @-N1@ and under any other @-N@
-- ('Test.Support.Owned.withOwnedThreadOn').
--
-- /Ownership./ The worker and the killer are owned starts. The killer is started with the worker, before the code under test
-- runs, and waits at a gate that only the arm opens; it is /not/ started by the arm. Its scope therefore encloses the whole
-- run of the worker, so arming never stops or joins it: the cancellation it was started to deliver stays pending against the
-- worker until the worker has received it, and where it lands is unchanged. When the worker has answered (a return, a failure,
-- the cancellation taken) or the example ends some other way, the scope has stopped and joined both threads. A killer that was
-- never armed is let go by the scope's opening, which disarms it: it does not throw.
--
-- State owner: this function owns both threads and the cells between them. Readers/writers: the worker (the answer, the arm),
-- the killer (the gate), the example thread (the answer). Thread: two per call. Lifetime: the call. Disposal: the scope's
-- release. Nothing sleeps. @base@ and "Test.Support.Owned" only.
module Test.Vulkan.Proof.PendingCancellation
  ( withCancelledWorker
  ) where

import Control.Concurrent (ThreadId, throwTo, yield)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, readMVar, takeMVar, tryPutMVar)
import Control.Exception (SomeException, try)
import Control.Monad (void, when)
import GHC.Conc (BlockReason (BlockedOnException), ThreadStatus (ThreadBlocked, ThreadDied, ThreadFinished), threadStatus)
import Test.Support.Owned (withOwnedThreadOn, withOwnedThreadOpeningOn)

-- | Run the action on a worker pinned to the capability, and answer how it ended. The action is given the /arm/: called on the
-- worker, it makes the given cancellation of the worker certainly pending, by releasing a killer that is already waiting on the
-- same capability and waiting until that killer is blocked delivering to the (masked) worker, or has finished. It returns at
-- once if called when the worker is not masked, because the killer then delivers immediately, in the arm, which is the
-- unprotected outcome the examples exist to tell apart.
--
-- The arm may be called at most once to any effect; a second call finds the gate open and the killer done or blocked.
withCancelledWorker ∷ Int → SomeException → (IO () → IO a) → IO (Either SomeException a)
withCancelledWorker capability cancellation action = do
  answered ← newEmptyMVar
  killerCell ← newEmptyMVar
  gate ← newEmptyMVar
  -- 'True' fires the killer, 'False' disarms it: only the arm says 'True', only the scope's release says 'False'.
  let arm = do
        killer ← readMVar killerCell
        void (tryPutMVar gate True)
        awaitPendingThrow killer
  withOwnedThreadOn capability (try @SomeException (action arm) >>= putMVar answered) $ \worker _ →
    withOwnedThreadOpeningOn capability (void (tryPutMVar gate False)) (readMVar gate >>= \fire → when fire (throwTo worker cancellation)) $ \killer _ → do
      putMVar killerCell killer
      -- The example still waits for the worker's own answer, as it did before the threads were owned.
      takeMVar answered

-- | Wait until a thread is blocked delivering an exception, or has finished.
--
-- 'throwTo' does not return until its exception has been raised in the target, and it blocks while the target is masked. So a
-- killer sitting in 'BlockedOnException' is exactly the state "a cancellation is pending against the target, and will be taken
-- the moment it is unmasked", and waiting for that state is what makes the examples deterministic instead of timed: no sleep,
-- no timeout, no repeated attempt. 'yield' is the only thing the wait does, and it is not interruptible, so it cannot itself
-- become the place the cancellation lands.
awaitPendingThrow ∷ ThreadId → IO ()
awaitPendingThrow killer =
  threadStatus killer >>= \case
    ThreadBlocked BlockedOnException → pure ()
    -- A killer that is already done raised its exception before returning, so there is nothing left to wait for either way.
    ThreadFinished → pure ()
    ThreadDied → pure ()
    _ → yield *> awaitPendingThrow killer
