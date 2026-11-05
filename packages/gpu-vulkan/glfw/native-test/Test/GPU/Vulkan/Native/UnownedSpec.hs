-- | The negative controls' own cleanup is uninterruptible (#596), proven without a session, a display or consent.
--
-- A control leaves a thread running on purpose and stops and joins it afterwards through the stop-and-join it registered with
-- its 'Cleanups' ("Test.GPU.Vulkan.Native.Unowned"). That cleanup is run through @finally@, which masks only interruptibly, so
-- unless the registered stop-and-join protects itself, a cancellation delivered while its kill or its join blocks aborts it and
-- leaves the control's thread running for the rest of the process. The same pattern, with the same two scenarios and the same
-- negative controls, as the GLFW native suite's (#594, rounds 1 to 3), which this suite cannot import.
--
-- * The cleanup is cancelled while its kill is blocked (the worker is held where only its own unmasking can receive the kill):
--   protected, it defers the cancellation, stops and joins the worker; interruptible, it takes the cancellation, is abandoned,
--   and the worker goes on to the wait only the kill can end.
-- * The example itself is cancelled after the cleanup's runner has blocked in its kill and before the worker is let go: the
--   runner's scope opens the gate before it joins, so the example unwinds by itself with its worker ended.
--
-- They are selected with @--match "the negative controls' own cleanup"@, and nothing here sleeps: every wait is a gate, an MVar
-- or the runtime's report of what a thread is blocked on, and the bound exists only to keep a stuck example from hanging the run.
module Test.GPU.Vulkan.Native.UnownedSpec (spec) where

import Control.Concurrent (ThreadId, myThreadId, throwTo, yield)
import Control.Concurrent.MVar (MVar, newEmptyMVar, putMVar, readMVar, tryPutMVar, tryReadMVar)
import Control.Exception (AsyncException (UserInterrupt), SomeException, fromException, finally, try, uninterruptibleMask_)
import Control.Monad (void)
import Test.Hspec (Spec, describe, it, shouldBe)
import Test.Support.Bounded (bounded)
import Test.Support.Cancel (awaitBlockedSending)
import Test.Support.Owned (withOwnedThreadOpening)

import Test.GPU.Vulkan.Native.Unowned (Cleanups, hasEnded, newCleanups, runCleanups, unownedScopeProtecting)

spec ∷ Spec
spec = describe "the negative controls' own cleanup (#596)" $ do
  it "is not abandoned by a cancellation delivered while the kill is blocked, so the worker it registered is stopped and joined" $
    cleanupCancelled uninterruptibleMask_ >>= (`shouldBe` True)
  it "negative control: an interruptible cleanup is abandoned by that cancellation and leaves the worker alive" $
    cleanupCancelled id >>= (`shouldBe` False)
  it "unwinds by itself, its worker ended, when the example is cancelled after the kill blocks and before the worker is let go" $
    cleanupCancelledEarly True >>= (`shouldBe` True)
  it "negative control: without the gate opened by the runner's scope and the independent stop, that cancellation leaves the example unable to unwind" $
    cleanupCancelledEarly False >>= (`shouldBe` False)

-- | What the scenarios share: the unowned worker's records, the gate it is held at (uninterruptibly, so only its own unmasking
-- can receive the kill) and the wait at the end that only the kill can end.
data Rig = Rig
  { rigCleanups ∷ Cleanups
  , rigWho ∷ MVar ThreadId
  , rigHeld ∷ MVar ()
  , rigGate ∷ MVar ()
  , rigNever ∷ MVar ()
  }

newRig ∷ IO Rig
newRig = Rig <$> newCleanups <*> newEmptyMVar <*> newEmptyMVar <*> newEmptyMVar <*> newEmptyMVar

-- | Let the worker go on to its last wait. Idempotent and not blocking.
openGate ∷ Rig → IO ()
openGate rig = void (tryPutMVar (rigGate rig) ())

-- | The independent, uninterruptible stop-and-join of everything a scenario started, run however the scenario ends: both waits
-- opened, then every registered cleanup (the kill and the join of the worker, which is idempotent).
stopAll ∷ Rig → IO ()
stopAll rig = uninterruptibleMask_ (openGate rig >> void (tryPutMVar (rigNever rig) ()) >> runCleanups (rigCleanups rig))

-- | Start the unowned worker in the control's scope with the given protection for its registered cleanup, and wait until it is
-- held at the gate.
startWorker ∷ (IO () → IO ()) → Rig → IO ThreadId
startWorker protect rig = do
  unownedScopeProtecting
    protect
    (rigCleanups rig)
    (pure ())
    (myThreadId >>= putMVar (rigWho rig) >> putMVar (rigHeld rig) () >> uninterruptibleMask_ (readMVar (rigGate rig)) >> readMVar (rigNever rig))
    (\_ _ → readMVar (rigHeld rig))
  readMVar (rigWho rig)

-- | The cleanup a control registers for the unowned thread it leaves, run on a thread of its own and cancelled while its kill is
-- blocked: the worker is held where only its own unmasking can receive the kill, so the cleanup blocks in @killThread@, the
-- cancellation is aimed at it there, and only then is the worker let go. A cleanup that is not interruptible defers the
-- cancellation until it has stopped and joined the worker (which then has ended); an interruptible one takes the cancellation in
-- the blocked kill, is abandoned, and never sends the kill, so the worker goes on to the wait only the kill can end. Every exit
-- stops what the scenario started: the runner's scope opens the gate before it joins, and the whole scenario ends in 'stopAll'.
cleanupCancelled ∷ (IO () → IO ()) → IO Bool
cleanupCancelled protect = bounded $ do
  rig ← newRig
  result ← newEmptyMVar
  -- The worker's wait at the end is reachable from this scenario's frame until it has judged, so the runtime does not end the
  -- worker as deadlocked; it is then let go whatever happened.
  ( do
      worker ← startWorker protect rig
      withOwnedThreadOpening (openGate rig) (try @SomeException (runCleanups (rigCleanups rig)) >>= putMVar result) $ \runner runnerEnded → do
        blockedKill ← awaitBlockedSending runner
        blockedKill `shouldBe` True
        withOwnedThreadOpening (pure ()) (throwTo runner UserInterrupt) $ \canceller _ → do
          -- Deferred (the thrower stays blocked) when the cleanup cannot be interrupted; taken (the thrower ends and the cleanup
          -- is abandoned) when it can. A thrower handing its exception to an interruptible target is blocked for an instant
          -- too, so the worker is let go only once the cleanup has either ended or kept holding for a count of scheduler yields
          -- (never a duration, as in 'hasEnded'): the cleanup that cannot be interrupted never ends here.
          void (awaitBlockedSending canceller)
          settles result
          openGate rig
          -- Whether the cancellation reached the runner before it finished is not the property: a throw still in transit when a
          -- cleanup that cannot be interrupted ends is dropped. The property is the worker.
          runnerEnded
      hasEnded worker
    )
    `finally` stopAll rig

-- | The interval before the gate is opened: the example itself is cancelled after the cleanup's runner has blocked in its kill
-- and before the worker is let go. The runner is uninterruptible and waits for a worker that waits at a gate, so a scope that
-- joins the runner before it opens the gate never unwinds. @rescued@ is the scenario with the runner's scope opening the gate and
-- the whole ending in 'stopAll'; without it nothing but the outer scope's opening rescues the example, which is the negative
-- control. The answer is whether the example unwound by itself, with its worker ended.
cleanupCancelledEarly ∷ Bool → IO Bool
cleanupCancelledEarly rescued = bounded $ do
  rig ← newRig
  interval ← newEmptyMVar
  hold ← newEmptyMVar ∷ IO (MVar ())
  result ← newEmptyMVar
  outcome ← newEmptyMVar
  let scenario =
        ( do
            _ ← startWorker uninterruptibleMask_ rig
            withOwnedThreadOpening (if rescued then openGate rig else pure ()) (try @SomeException (runCleanups (rigCleanups rig)) >>= putMVar result) $ \runner _ → do
              void (awaitBlockedSending runner)
              putMVar interval ()
              readMVar hold
        )
          `finally` (if rescued then stopAll rig else pure ())
  ( withOwnedThreadOpening (openGate rig >> void (tryPutMVar hold ())) (try @SomeException scenario >>= putMVar outcome) $ \scenarioThread _ → do
      readMVar interval
      throwTo scenarioThread UserInterrupt
      settles outcome
      unwound ← maybe False cancelled <$> tryReadMVar outcome
      if unwound then readMVar (rigWho rig) >>= hasEnded else pure False
    )
    `finally` stopAll rig
  where
    cancelled = either ((== Just UserInterrupt) . fromException) (const False)

-- | Wait for the answer of the cleanup's runner, or give up after a count of yields: the runner of a cleanup that cannot be
-- interrupted answers only after the worker has been let go.
settles ∷ MVar a → IO ()
settles result = go (100000 ∷ Int)
  where
    go 0 = pure ()
    go remaining = tryReadMVar result >>= maybe (yield >> go (remaining - 1)) (const (pure ()))
