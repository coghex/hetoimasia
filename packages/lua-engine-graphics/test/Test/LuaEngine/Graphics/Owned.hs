-- | The threads the graphics adapter's helpers start are owned (#599): however the scope that needed a thread ends, the thread
-- has ended and been joined before the scope returns.
--
-- Each shape has an example that ends the scope while the thread is parked, and judges that the thread has ended and been joined,
-- and a negative control that applies the same judgement to the start the helper made before it was converted and must fail:
--
-- * 'withFakeOwner' and 'mainLoop': the body is cancelled between the fork and the first step of the body, which is where the
--   previous helpers (the thread forked, then the stop-and-join installed after) left the thread. The seam that places the
--   cancellation there exists in the helper test-side only ('withFakeOwnerAs', 'mainLoopAs'); no example passes anything else.
-- * 'withForkedScope': a scope held at a gate it waits at uninterruptibly ends with the example, and its thread has ended and
--   been joined, whether the example fails or is cancelled while it is held; and the real drain a scope waits in, which the
--   stop lets go of and latches, so a worker cancelled before it installs its holds cannot reinstall them afterwards.
-- * 'withServedBoundThread': the loop that serves a bound profile thread is served again when it is left abnormally, until the
--   thread has ended.
--
-- A control's own cleanup is registered in the same masked step that starts what it leaves, before anything can cancel it, and
-- runs not interruptibly on every exit, after the judgement is recorded: it lets go of every gate, kills and joins. Each row also
-- has a coordinated cancellation example: the helper or the control is cancelled at once, and nothing it started is alive once
-- it has returned or raised.
--
-- State owner: each example owns the cells it passes its helper and its 'Cleanups'. Thread: the helper's. Lifetime: the example's.
-- Nothing here sleeps: every wait is an @MVar@, a hold or the runtime's report of a thread, and a bound exists only to keep a
-- stuck example from hanging the run.
module Test.LuaEngine.Graphics.Owned (spec) where

import Control.Concurrent (ThreadId, forkIO, killThread, yield)
import Control.Concurrent.MVar (isEmptyMVar, newEmptyMVar, putMVar, readMVar, takeMVar, tryPutMVar)
import Control.Concurrent.STM (atomically, retry)
import Control.Exception (AsyncException (UserInterrupt), Exception, SomeException, finally, mask_, throwIO, try, uninterruptibleMask_)
import Control.Monad (forever, unless, void)
import Data.Foldable (for_)
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import Hetoimasia.LuaEngine.Graphics.Window.Provider (WindowConfig (..), WindowProvider, noProviderHooks, windowMainReady, windowMainStep, withWindowProviderWith)
import Test.Hspec
import Test.LuaEngine.Graphics.Fake
import Test.LuaEngine.Graphics.PeersRig (mainLoopAs, retarget)
import Test.LuaEngine.Graphics.Rig
import Test.LuaEngine.Graphics.Served (withServedBoundThread)
import Test.LuaEngine.Graphics.Unowned
import qualified Test.LuaEngine.Graphics.Window.Fake as WF
import Test.Support.Cancel (withCancellationAfter)

-- | Record a thread: in the same masked step that starts it, for a control, so what it leaves is known before anything can cancel it.
note ∷ IORef [ThreadId] → ThreadId → IO ()
note seen thread = atomicModifyIORef' seen (\held → (thread : held, ()))

-- | The fake owner as the helper had it before #599: the thread forked, and its stop-and-join installed after the fork
-- returned, so a cancellation delivered in between (the seam) leaves the thread. The thread is recorded for the control's own
-- cleanup in the step that starts it. Nothing else differs from 'withFakeOwnerAs'.
previousWithFakeOwner ∷ IORef [ThreadId] → (ThreadId → IO ()) → Fake → IO a → IO a
previousWithFakeOwner seen seam fake body = do
  done ← newEmptyMVar
  thread ← mask_ (forkIO (ownerLoop fake `finally` putMVar done ()) >>= \started → note seen started >> pure started)
  seam thread
  body `finally` (killThread thread >> takeMVar done)

-- | The main-step loop as the helper had it before #599, cut and recorded in the same way.
previousMainLoop ∷ IORef [ThreadId] → (ThreadId → IO ()) → WindowProvider Int → IO a → IO a
previousMainLoop seen seam provider action = do
  ended ← newEmptyMVar
  thread ←
    mask_
      ( forkIO (forever (atomically (windowMainReady provider >>= \ready → unless ready retry) >> windowMainStep provider) `finally` putMVar ended ())
          >>= \started → note seen started >> pure started
      )
  seam thread
  action `finally` (killThread thread >> takeMVar ended)

-- | The scope-on-a-thread helper as it was before #599: the thread forked, its outcome and end kept in cells the caller must
-- take, and nothing stopping or joining it when the caller ends. The control's own cleanup (let the gate go, kill, wait for the
-- end) is registered in the step that starts the thread. The negative control judges it.
previousForkScope ∷ Cleanups → IO () → IO a → (Forked a → IO b) → IO b
previousForkScope cleanups open scope body = do
  result ← newEmptyMVar
  done ← newEmptyMVar
  thread ←
    mask_
      ( do
          started ← forkIO ((try @SomeException scope >>= putMVar result) `finally` putMVar done ())
          cleanupLater cleanups (open >> killThread started >> readMVar done)
          pure started
      )
  body Forked {forkedThread = thread, forkedJoin = takeMVar result <* takeMVar done}

-- | Record a thread, and cancel the example right there.
cancelHere ∷ IORef [ThreadId] → ThreadId → IO ()
cancelHere seen thread = note seen thread >> throwIO UserInterrupt

-- | End and join what a control left, not interruptibly, each even if an earlier one failed.
stopNoted ∷ IORef [ThreadId] → IO ()
stopNoted seen =
  uninterruptibleMask_ $ do
    threads ← readIORef seen
    for_ threads $ \thread → killThread thread `finally` void (hasEnded thread)

-- | Nothing the control or helper started is alive.
noneAlive ∷ IORef [ThreadId] → IO Bool
noneAlive seen = readIORef seen >>= fmap and . mapM hasEnded

-- | Wait until a thread has recorded itself.
waitNoted ∷ IORef [ThreadId] → IO ()
waitNoted seen = bounded go
  where
    go = readIORef seen >>= \held → if null held then yield >> go else pure ()

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

-- | A scope on a thread of its own, held at a gate it waits at uninterruptibly (as a drain waits for evidence only the example
-- supplies, so the kill alone cannot end it), with the example ended the way the ending says: whether the thread has ended and
-- been joined when the call returned. The gate is not let go by the example: only the stop does, which is the thing judged. A
-- control's own cleanup, registered by its start before anything can cancel it, lets the gate go and joins on every exit, after
-- the judgement is made. The gate is referenced by the example until then, so the runtime does not end the parked thread as
-- deadlocked.
gatedScope ∷ IORef [ThreadId] → Ending → (Cleanups → IO () → IO () → (Forked () → IO ()) → IO ()) → IO Bool
gatedScope seen ending start = do
  cleanups ← newCleanups
  gate ← newEmptyMVar
  let letGo = void (tryPutMVar gate ())
      scope = noteThread seen >> uninterruptibleMask_ (readMVar gate)
  ( do
      runEnding ending $ \end → start cleanups letGo scope $ \_ → end (waitNoted seen)
      joined ← allJoined seen
      -- the gate stays reachable until the judgement is made
      void (isEmptyMVar gate)
      pure joined
    )
    `finally` runCleanups cleanups

-- | A backend scope on a thread of its own, held in its drain by evidence only the example supplies, with the example ended the
-- way the ending says: whether the thread has ended and been joined when the call returned. Owned only: it is the real drain
-- that 'Test.LuaEngine.Graphics.Teardown' and 'Test.LuaEngine.Graphics.Lifecycle' hold, and a leaked one cannot be stopped
-- without the fake owner it needs, so no control leaves one.
heldDrain ∷ IORef [ThreadId] → Ending → IO Bool
heldDrain seen ending = do
  fake ← newFake defaultFakeConfig
  withFakeOwner fake $ do
    let scope = noteThread seen >> drainScope fake
    runEnding ending $ \end → withForkedScope (openEveryHold fake) scope $ \_ → end (bounded (awaitEvent fake "released"))
    allJoined seen

-- | The same drain, with the worker cancelled before it has installed its holds: it waits to start until the stop has let
-- everything go (the stop's opening is what starts it), and only then installs them. The stop latched the fake before it let
-- anything go, so the holds the worker installs afterwards hold nothing, and the drain the kill leaves it in can finish. Without
-- the latch the worker waits in a drain for evidence nobody supplies any more and the join never ends.
raceDrain ∷ IORef [ThreadId] → Ending → IO Bool
raceDrain seen ending = do
  fake ← newFake defaultFakeConfig
  start ← newEmptyMVar
  armed ← newEmptyMVar
  withFakeOwner fake $ do
    -- The worker installs its holds only once the stop has let everything go, and does it without being interruptible, so the kill
    -- the stop sends next can arrive only after they are installed: the drain it is then left in waits for them. The example
    -- ends only once the worker is parked there, so the stop is certain to reach it at that point.
    let scope = noteThread seen >> drainScopeAfter (void (tryPutMVar armed ()) >> readMVar start) fake
    runEnding ending $ \end → withForkedScope (openEveryHold fake >> void (tryPutMVar start ())) scope $ \_ → end (bounded (readMVar armed))
    allJoined seen

-- | A backend scope that installs the holds a drain then waits on.
drainScope ∷ Fake → IO ()
drainScope = drainScopeAfter (pure ())

-- | The same, installing the holds uninterruptibly once the given wait has returned.
drainScopeAfter ∷ IO () → Fake → IO ()
drainScopeAfter wait fake =
  withBackendOnRaw fake $ \rig → do
    probe ← newProbe
    _ ← submit rig probe 2 2 255
    _ ← awaitTerminal probe
    uninterruptibleMask_ (wait >> hold fake HoldReclaim >> setVersionHolders fake 1)

-- | The failure the first run of the loop raises.
data Boom = Boom
  deriving (Eq, Show)

instance Exception Boom

-- | The profile thread needs the loop served again to finish (as an example's window scope drains only as the loop services its
-- commands), and its wait is uninterruptible, so only serving ends it. The first run of the loop fails.
servedAfterFailure ∷ IORef [ThreadId] → IO Bool
servedAfterFailure seen = do
  needServing ← newEmptyMVar
  runs ← newIORef (0 ∷ Int)
  let profile = noteThread seen >> uninterruptibleMask_ (readMVar needServing)
      serve stopWhen = do
        run ← atomicModifyIORef' runs (\count → (count + 1, count))
        if run == 0
          then waitNoted seen >> throwIO Boom
          else void (tryPutMVar needServing ()) >> bounded (let go = stopWhen >>= \over → unless over (yield >> go) in go)
  outcome ← try @Boom (withServedBoundThread profile (pure False) serve)
  outcome `shouldBe` Left Boom
  joined ← allJoined seen
  void (isEmptyMVar needServing)
  pure joined

-- | The same profile thread, with a loop that always serves and an example cancelled at once: wherever the cancellation lands
-- the thread has ended once the call has raised.
servedWhileCancelled ∷ IORef [ThreadId] → IO ()
servedWhileCancelled seen = do
  needServing ← newEmptyMVar
  let profile = noteThread seen >> uninterruptibleMask_ (readMVar needServing)
      serve stopWhen = void (tryPutMVar needServing ()) >> bounded (let go = stopWhen >>= \over → unless over (yield >> go) in go)
  withServedBoundThread profile (pure False) serve
  void (isEmptyMVar needServing)

-- | Run the helper or control cancelled at once; whatever it started is not alive once it has returned or raised.
cancelledAtOnce ∷ (IORef [ThreadId] → IO ()) → IO Bool
cancelledAtOnce control = do
  seen ← newIORef []
  void (try @AsyncException (bounded (withCancellationAfter (pure ()) (pure ()) (control seen))))
  noneAlive seen

spec ∷ Spec
spec = describe "the threads the helpers start are owned (#599)" $ do
  describe "the fake graphics owner" $ do
    it "has ended and been joined when the body is cancelled between the fork and its first step" $ do
      seen ← newIORef []
      fakeOwnerCancelledAtStart withFakeOwnerAs seen >>= (`shouldBe` True)
    it "negative control: the previous helper leaves the thread when the body is cancelled between the fork and its first step" $ do
      seen ← newIORef []
      -- The judgement is recorded first; only then is the thread the control left stopped and joined.
      (fakeOwnerCancelledAtStart (previousWithFakeOwner seen) seen >>= (`shouldBe` False)) `finally` stopNoted seen
    it "leaves nothing alive when it is cancelled at once" $
      cancelledAtOnce (void . fakeOwnerCancelledAtStart withFakeOwnerAs) >>= (`shouldBe` True)
    it "leaves nothing alive when the control is cancelled at once" $
      cancelledAtOnce (\seen → void (fakeOwnerCancelledAtStart (previousWithFakeOwner seen) seen) `finally` stopNoted seen) >>= (`shouldBe` True)
  describe "the main-step loop" $ do
    it "has ended and been joined when the body is cancelled between the fork and its first step" $ do
      seen ← newIORef []
      mainLoopCancelledAtStart mainLoopAs seen >>= (`shouldBe` True)
    it "negative control: the previous helper leaves the thread when the body is cancelled between the fork and its first step" $ do
      seen ← newIORef []
      (mainLoopCancelledAtStart (previousMainLoop seen) seen >>= (`shouldBe` False)) `finally` stopNoted seen
    it "leaves nothing alive when it is cancelled at once" $
      cancelledAtOnce (void . mainLoopCancelledAtStart mainLoopAs) >>= (`shouldBe` True)
    it "leaves nothing alive when the control is cancelled at once" $
      cancelledAtOnce (\seen → void (mainLoopCancelledAtStart (previousMainLoop seen) seen) `finally` stopNoted seen) >>= (`shouldBe` True)
  for_ endings $ \(label, ending) →
    describe ("a scope on a thread of its own, held in its drain, when " <> label) $ do
      it "has ended and been joined when the call returns: the real drain's hold is let go by the stop" $ do
        seen ← newIORef []
        heldDrain seen ending >>= (`shouldBe` True)
      it "has ended and been joined when the worker had not installed its holds when the stop let everything go" $ do
        seen ← newIORef []
        raceDrain seen ending >>= (`shouldBe` True)
      it "has ended and been joined when the call returns: the gate it waits at uninterruptibly is let go by the stop" $ do
        seen ← newIORef []
        gatedScope seen ending (const withForkedScope) >>= (`shouldBe` True)
      it "negative control: the previous helper leaves the thread held at its gate" $ do
        seen ← newIORef []
        gatedScope seen ending previousForkScope >>= (`shouldBe` False)
  describe "the forked scope, cancelled at once" $ do
    it "leaves nothing alive" $
      cancelledAtOnce (\seen → void (gatedScope seen Cancelled (const withForkedScope))) >>= (`shouldBe` True)
    it "leaves nothing alive when the real drain is held" $
      cancelledAtOnce (\seen → void (heldDrain seen Cancelled)) >>= (`shouldBe` True)
    it "leaves nothing alive when the control is cancelled at once" $
      cancelledAtOnce (\seen → void (gatedScope seen Cancelled previousForkScope)) >>= (`shouldBe` True)
  describe "the loop that serves a bound profile thread" $ do
    it "is served again when it is left abnormally, until the thread has ended" $ do
      seen ← newIORef []
      servedAfterFailure seen >>= (`shouldBe` True)
    it "leaves nothing alive when it is cancelled at once" $
      cancelledAtOnce servedWhileCancelled >>= (`shouldBe` True)
