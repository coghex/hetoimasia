-- | The threads the graphics adapter's helpers start are owned (#599): however the scope that needed a thread ends, the thread
-- has ended and been joined before the scope returns.
--
-- Each shape has an example that ends the scope while the thread is parked, and judges that the thread has ended and been joined,
-- and a negative control that applies the same judgement to the start the helper made before it was converted and must fail:
--
-- * 'withFakeOwner' and 'mainLoop': the body is cancelled between the fork and the first step of the body, which is where the
--   previous helpers (the thread forked, then the stop-and-join installed after) left the thread. The seam that places the
--   cancellation there exists in the helper test-side only ('withFakeOwnerAs', 'mainLoopAs'); no example passes anything else.
-- * 'withForkedScope': a scope held in a drain only the example lets go of ends with the example, and its thread has ended and
--   been joined, whether the example fails or is cancelled while it is held.
--
-- State owner: each example owns the cells it passes its helper and its 'Cleanups'. Thread: the helper's. Lifetime: the example's.
-- Disposal: the facility's release, or, for a control, 'runCleanups' or 'stopNoted' after the judgement has been recorded.
-- Nothing here sleeps: every wait is an @MVar@, a hold or the runtime's report of a thread, and a bound exists only to keep a
-- stuck example from hanging the run.
module Test.LuaEngine.Graphics.Owned (spec) where

import Control.Concurrent (ThreadId, forkIO, killThread, yield)
import Control.Concurrent.MVar (isEmptyMVar, newEmptyMVar, putMVar, readMVar, takeMVar, tryPutMVar)
import Control.Exception (AsyncException (UserInterrupt), SomeException, finally, throwIO, try, uninterruptibleMask_)
import Control.Monad (forever, unless, void, when)
import Control.Concurrent.STM (atomically, retry)
import Data.Foldable (for_)
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import Hetoimasia.LuaEngine.Graphics.Window.Provider (WindowConfig (..), WindowProvider, noProviderHooks, windowMainReady, windowMainStep, withWindowProviderWith)
import Test.Hspec
import Test.LuaEngine.Graphics.Fake
import Test.LuaEngine.Graphics.PeersRig (mainLoopAs, retarget)
import Test.LuaEngine.Graphics.Rig
import Test.LuaEngine.Graphics.Unowned
import qualified Test.LuaEngine.Graphics.Window.Fake as WF

-- | The fake owner as the helper had it before #599: the thread forked, and its stop-and-join installed after the fork
-- returned, so a cancellation delivered in between (the seam) leaves the thread. Nothing else differs from 'withFakeOwnerAs'.
previousWithFakeOwner ∷ (ThreadId → IO ()) → Fake → IO a → IO a
previousWithFakeOwner seam fake body = do
  done ← newEmptyMVar
  thread ← forkIO (ownerLoop fake `finally` putMVar done ())
  seam thread
  body `finally` (killThread thread >> takeMVar done)

-- | The main-step loop as the helper had it before #599, cut in the same place.
previousMainLoop ∷ (ThreadId → IO ()) → WindowProvider Int → IO a → IO a
previousMainLoop seam provider action = do
  ended ← newEmptyMVar
  thread ← forkIO (forever (atomically (windowMainReady provider >>= \ready → unless ready retry) >> windowMainStep provider) `finally` putMVar ended ())
  seam thread
  action `finally` (killThread thread >> takeMVar ended)

-- | Record a thread, and cancel the example right there.
cancelHere ∷ IORef [ThreadId] → ThreadId → IO ()
cancelHere seen thread = atomicModifyIORef' seen (\held → (thread : held, ())) >> throwIO UserInterrupt

-- | End and join what a control left, newest first, each even if an earlier one failed.
stopNoted ∷ IORef [ThreadId] → IO ()
stopNoted seen = do
  threads ← readIORef seen
  for_ threads $ \thread → killThread thread `finally` void (hasEnded thread)

-- | A fake owner started by this helper whose example is cancelled between the fork and the first step of its body: whether the
-- thread has ended and been joined once the call raised.
fakeOwnerCancelledAtStart ∷ ((ThreadId → IO ()) → Fake → IO () → IO ()) → IORef [ThreadId] → IO Bool
fakeOwnerCancelledAtStart start seen = do
  fake ← newFake defaultFakeConfig
  outcome ← try @AsyncException (bounded (start (cancelHere seen) fake (pure ())))
  either (`shouldBe` UserInterrupt) (const (expectationFailure "the cancellation was lost")) outcome
  joined ← allJoined seen
  -- the fake stays reachable until the judgement is made, so the runtime does not end the parked thread as deadlocked
  void (events fake)
  pure joined

-- | The same for the main-step loop, over a window provider of the suite's fake windows.
mainLoopCancelledAtStart ∷ ((ThreadId → IO ()) → WindowProvider Int → IO () → IO ()) → IORef [ThreadId] → IO Bool
mainLoopCancelledAtStart start seen = do
  windows ← WF.newFake WF.defaultFakeConfig
  let config = WindowConfig 2 (pure ()) (\_ → pure ())
  withWindowProviderWith noProviderHooks config (retarget (WF.fakePort windows)) $ \provider → do
    outcome ← try @AsyncException (bounded (start (cancelHere seen) provider (pure ())))
    either (`shouldBe` UserInterrupt) (const (expectationFailure "the cancellation was lost")) outcome
    joined ← allJoined seen
    -- the provider stays reachable until the judgement is made, so the runtime does not end the parked thread as deadlocked
    void (atomically (windowMainReady provider))
    pure joined

-- | The scope-on-a-thread helper as it was before #599: the thread forked, its outcome and end kept in cells the caller must
-- take, and nothing stopping or joining it when the caller ends. The negative control judges it.
previousForkScope ∷ IO () → IO a → (Forked a → IO b) → IO b
previousForkScope _ scope body = do
  result ← newEmptyMVar
  done ← newEmptyMVar
  thread ← forkIO ((try @SomeException scope >>= putMVar result) `finally` putMVar done ())
  body Forked {forkedThread = thread, forkedJoin = takeMVar result <* takeMVar done}

-- | A scope on a thread of its own, held at a gate it waits at uninterruptibly (as a drain waits for evidence only the example
-- supplies, so the kill alone cannot end it), with the example ended the way the ending says: whether the thread has ended and
-- been joined when the call returned. The gate is not let go by the example: only the stop does, which is the thing judged. A
-- control lets the gate go itself afterwards, so the thread ends of its own accord and nothing waits for a kill; the judgement is
-- made first. The gate is referenced by the example until then, so the runtime does not end the parked thread as deadlocked.
gatedScope ∷ Ending → (IO () → IO () → (Forked () → IO ()) → IO ()) → Bool → IO Bool
gatedScope ending start letGoAfterwards = do
  seen ← newIORef []
  gate ← newEmptyMVar
  let letGo = void (tryPutMVar gate ())
      scope = noteThread seen >> uninterruptibleMask_ (readMVar gate)
  runEnding ending $ \end → start letGo scope $ \_ → end (waitUntilNoted seen)
  joined ← allJoined seen
  when letGoAfterwards letGo
  -- the gate stays reachable until the judgement is made
  void (isEmptyMVar gate)
  pure joined
  where
    waitUntilNoted seen = bounded (let go = readIORef seen >>= \held → if null held then yield >> go else pure () in go)

-- | A backend scope on a thread of its own, held in its drain by evidence only the example supplies, with the example ended the
-- way the ending says: whether the thread has ended and been joined when the call returned. Owned only: it is the real drain
-- that 'Test.LuaEngine.Graphics.Teardown' and 'Test.LuaEngine.Graphics.Lifecycle' hold, and a leaked one cannot be stopped
-- without the fake owner it needs, so no control leaves one.
heldDrain ∷ Ending → IO Bool
heldDrain ending = do
  fake ← newFake defaultFakeConfig
  seen ← newIORef []
  withFakeOwner fake $ do
    let scope = noteThread seen >> withBackendOnRaw fake (\rig → do
          probe ← newProbe
          _ ← submit rig probe 2 2 255
          _ ← awaitTerminal probe
          hold fake HoldReclaim
          setVersionHolders fake 1)
    runEnding ending $ \end → withForkedScope (openEveryHold fake) scope $ \_ → end (bounded (awaitEvent fake "released"))
    allJoined seen

spec ∷ Spec
spec = describe "the threads the helpers start are owned (#599)" $ do
  describe "the fake graphics owner" $ do
    it "has ended and been joined when the body is cancelled between the fork and its first step" $ do
      seen ← newIORef []
      fakeOwnerCancelledAtStart withFakeOwnerAs seen >>= (`shouldBe` True)
    it "negative control: the previous helper leaves the thread when the body is cancelled between the fork and its first step" $ do
      seen ← newIORef []
      -- The judgement is recorded first; only then is the thread the control left stopped and joined.
      (fakeOwnerCancelledAtStart previousWithFakeOwner seen >>= (`shouldBe` False)) `finally` stopNoted seen
  describe "the main-step loop" $ do
    it "has ended and been joined when the body is cancelled between the fork and its first step" $ do
      seen ← newIORef []
      mainLoopCancelledAtStart mainLoopAs seen >>= (`shouldBe` True)
    it "negative control: the previous helper leaves the thread when the body is cancelled between the fork and its first step" $ do
      seen ← newIORef []
      (mainLoopCancelledAtStart previousMainLoop seen >>= (`shouldBe` False)) `finally` stopNoted seen
  for_ endings $ \(label, ending) →
    describe ("a scope on a thread of its own, held in its drain, when " <> label) $ do
      it "has ended and been joined when the call returns: the real drain's hold is let go by the stop" $
        heldDrain ending >>= (`shouldBe` True)
      it "has ended and been joined when the call returns: the gate it waits at uninterruptibly is let go by the stop" $
        gatedScope ending withForkedScope False >>= (`shouldBe` True)
      it "negative control: the previous helper leaves the thread held at its gate" $
        gatedScope ending previousForkScope True >>= (`shouldBe` False)
