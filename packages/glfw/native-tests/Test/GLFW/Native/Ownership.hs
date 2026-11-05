-- | The ownership regressions of the helpers that start the native suite's threads (#594).
--
-- These examples need no consent, session or display and belong to the approval-free selection
-- @--match "the native opt-in"@. For each converted helper they end the scope that needed its thread while the thread is parked,
-- by a failing body and by a cancellation, and judge that the thread has ended and been joined when the scope returns. Each has
-- a negative control: the same scenario through the unowned start the helper made before it was converted
-- ("Test.GLFW.Native.Unowned"), where the same judgement must fail. A control records its failed judgement first and then
-- stops and joins what it left, even if an assertion fails.
--
-- Every scenario runs the helper's real code path, not a copy: only the start is swapped ('Scope') and, where a cancellation
-- has to land at an instant no example can reach from outside, a test-side step or stand-in read is supplied ('runOwnedIn''s
-- step, 'Waits'). No production value or default changes. The sites that need a session ('Private', the Wayland scenarios,
-- and the wake examples themselves) are covered by their own examples still passing in the display groups.
--
-- State owner: each scenario. Threads: the helper's own, one per scenario, and the delivering helper an ending owns. Nothing
-- sleeps.
module Test.GLFW.Native.Ownership (spec, withLauncher) where

import Control.Concurrent (ThreadId, isCurrentThreadBound, myThreadId, throwTo, yield)
import Control.Concurrent.MVar (MVar, newEmptyMVar, putMVar, readMVar, tryPutMVar)
import Control.Concurrent.STM (atomically)
import Control.Exception (AsyncException (UserInterrupt), IOException, SomeException, finally, throwIO, try, uninterruptibleMask_)
import Control.Monad (void, when)
import Data.Foldable (for_)
import Data.IORef (newIORef, readIORef, writeIORef)
import Hetoimasia.Foundation.Resource (allocResource)
import System.Posix.Signals (nullSignal, sigKILL, signalProcess, signalProcessGroup)
import qualified Test.GLFW.Native.Child as Child
import Test.GLFW.Native.Fixture (Owner (..), runOwnedIn)
import Test.GLFW.Native.Harness (withForkedIn)
import Test.GLFW.Native.Support (onThreadIn)
import Test.GLFW.Native.Threads (Boundness (..), Scope, ownedScope, startIn)
import Test.GLFW.Native.Unowned
  ( Boom (..)
  , Cleanups
  , Ending (..)
  , cleanupLater
  , endBody
  , endedAs
  , endedFromOutside
  , endings
  , hasEnded
  , newCleanups
  , runCleanups
  , unownedScope
  , unownedScopeProtecting
  )
import Test.GLFW.Native.Wake (Waits (..), wokenWaitIn)
import Test.Hspec (Spec, describe, it, shouldBe)
import Test.Support.Bounded (bounded)
import Test.Support.Cancel (awaitBlockedSending)

spec ∷ Spec
spec = describe "owns the threads its helpers start (#594)" $ do
  describe "onThread" $
    for_ [("an unbound", Unbound), ("a bound", Bound)] $ \(kind, boundness) →
      for_ endings $ \(label, ending) → do
        let ran scope cleanups = onThreadHeld scope cleanups boundness ending
        it ("has ended and been joined " <> kind <> " thread when " <> label <> " while it is parked") $
          (newCleanups >>= \cleanups → ran ownedScope cleanups `finally` runCleanups cleanups) >>= (`shouldBe` True)
        it ("negative control: the unowned start leaves " <> kind <> " thread running when " <> label <> " while it is parked") $ do
          cleanups ← newCleanups
          (ran (unownedScope cleanups) cleanups >>= (`shouldBe` False)) `finally` runCleanups cleanups

  describe "the controls' own cleanup" $ do
    it "is not abandoned by a cancellation delivered while the kill is blocked, so the worker it registered is stopped and joined" $
      cleanupCancelled uninterruptibleMask_ >>= (`shouldBe` True)
    it "negative control: an interruptible cleanup is abandoned by that cancellation and leaves the worker alive" $
      cleanupCancelled id >>= (`shouldBe` False)

  describe "runOwned's borrower" $
    for_ endings $ \(label, ending) → do
      it ("has ended and been joined when " <> label <> " between the borrower's start and the settlement, the borrower parked") $
        (newCleanups >>= \cleanups → borrowerHeld ownedScope cleanups ending `finally` runCleanups cleanups) >>= (`shouldBe` True)
      it ("negative control: an unowned borrower is left parked when " <> label <> " between its start and the settlement") $ do
        cleanups ← newCleanups
        (borrowerHeld (unownedScope cleanups) cleanups ending >>= (`shouldBe` False)) `finally` runCleanups cleanups

  describe "wokenWaitBy's observer worker" $
    for_ [("an unbound", Unbound), ("a bound", Bound)] $ \(kind, boundness) →
      for_ endings $ \(label, ending) → do
        it ("has ended and is not spinning, " <> kind <> " worker, when " <> label <> " before any wait blocks") $
          (newCleanups >>= \cleanups → observerHeld ownedScope cleanups boundness ending `finally` runCleanups cleanups) >>= (`shouldBe` True)
        it ("negative control: the unowned worker, " <> kind <> ", is still running when " <> label <> " before any wait blocks") $ do
          cleanups ← newCleanups
          (observerHeld (unownedScope cleanups) cleanups boundness ending >>= (`shouldBe` False)) `finally` runCleanups cleanups

  describe "the harness's forked thread" $
    for_ [("parked", False), ("held at a gate only its scope opens", True)] $ \(where', gated) →
      for_ endings $ \(label, ending) → do
        it ("has ended and been joined when " <> label <> " while it is " <> where') $
          (newCleanups >>= \cleanups → forkedHeld ownedScope cleanups gated ending `finally` runCleanups cleanups) >>= (`shouldBe` True)
        it ("negative control: the unowned thread is left " <> where' <> " when " <> label) $ do
          cleanups ← newCleanups
          (forkedHeld (unownedScope cleanups) cleanups gated ending >>= (`shouldBe` False)) `finally` runCleanups cleanups

  describe "the launcher thread of the launch-interruption example" $
    for_ endings $ \(label, ending) → do
      it ("has ended and been joined, its child reaped and its readers finished, when " <> label <> " while the launch runs") $
        (newCleanups >>= \cleanups → launcherHeld ownedScope cleanups ending `finally` runCleanups cleanups) >>= (`shouldBe` True)
      it ("negative control: an unowned launcher and its child are left running when " <> label) $ do
        cleanups ← newCleanups
        (launcherHeld (unownedScope cleanups) cleanups ending >>= (`shouldBe` False)) `finally` runCleanups cleanups

-- | What a parked thread records of itself, and the gate it waits at.
data Parked = Parked
  { parkedWho ∷ MVar (ThreadId, Bool)
    -- ^ The thread, and whether it is OS-bound.
  , parkedSignal ∷ MVar ()
  , parkedGate ∷ MVar ()
  }

-- | A parked thread's records. The gate is registered with the control so it stays reachable while the control judges.
newParked ∷ Cleanups → IO Parked
newParked cleanups = do
  parked ← Parked <$> newEmptyMVar <*> newEmptyMVar <*> newEmptyMVar
  cleanupLater cleanups (void (tryPutMVar (parkedGate parked) ()))
  pure parked

-- | Record the thread, say it is parked, and wait at the gate. Only the first caller records and parks.
park ∷ Parked → IO ()
park parked = do
  me ← myThreadId
  bound ← isCurrentThreadBound
  first ← tryPutMVar (parkedWho parked) (me, bound)
  when first (putMVar (parkedSignal parked) () >> readMVar (parkedGate parked))

reached ∷ Parked → IO ()
reached = readMVar . parkedSignal

-- | Run a scenario under a bound, so a stuck example fails instead of hanging the run.
inBounds ∷ IO a → IO a
inBounds = bounded

-- | The thread the scenario parked has ended and been joined, and is of the boundness asked for.
judged ∷ Parked → Maybe Boundness → IO Bool
judged parked expectedBoundness = do
  (thread, bound) ← readMVar (parkedWho parked)
  ended ← hasEnded thread
  pure (ended && maybe True (\b → bound == (b == Bound)) expectedBoundness)

-- | 'Test.GLFW.Native.Support.onThread': its caller ends while the thread it waits for is parked.
onThreadHeld ∷ Scope → Cleanups → Boundness → Ending → IO Bool
onThreadHeld scope cleanups boundness ending = do
  parked ← newParked cleanups
  outcome ← inBounds (endedFromOutside ending (reached parked) (onThreadIn scope boundness (park parked)))
  endedAs ending outcome `shouldBe` True
  judged parked (Just boundness)

-- | 'Test.GLFW.Native.Fixture.runOwned': the owner is ended between the borrower's start and the installation of the settlement.
-- The borrower is parked and never dispatches, so only the scope can end it.
borrowerHeld ∷ Scope → Cleanups → Ending → IO Bool
borrowerHeld scope cleanups ending = do
  parked ← newParked cleanups
  let owner = Owner {ownerAcquire = allocResource (pure ()) (\_ → pure ()), ownerSettled = pure ()}
      step = do
        reached parked
        case ending of
          Raises → throwIO Boom
          Cancelled → myThreadId >>= \me → throwTo me UserInterrupt
  outcome ← try @SomeException (inBounds (runOwnedIn scope step owner (\_ → park parked)))
  endedAs ending outcome `shouldBe` True
  judged parked (Just Unbound)

-- | 'Test.GLFW.Native.Wake.wokenWaitIn': the owner side ends before any wait blocks, while the observer worker is inside its
-- observation. The stand-ins need no session: the owner's wait is the ending itself.
observerHeld ∷ Scope → Cleanups → Boundness → Ending → IO Bool
observerHeld scope cleanups boundness ending = do
  parked ← newParked cleanups
  let waits =
        Waits
          { waitsAwait = endBody ending (reached parked)
          , waitsLast = pure (0, False)
          , waitsObserve = park parked >> yield >> pure Nothing
          }
  outcome ← try @SomeException (inBounds (void (wokenWaitIn scope waits boundness 0 (pure ()))))
  endedAs ending outcome `shouldBe` True
  judged parked (Just boundness)

-- | 'Test.GLFW.Native.Harness.withForkedIn': the thread is parked, or held where a kill cannot reach it until the gate opens.
-- The scope's opening is what opens that gate.
forkedHeld ∷ Scope → Cleanups → Bool → Ending → IO Bool
forkedHeld scope cleanups gated ending = do
  parked ← newParked cleanups
  let hold = if gated then uninterruptibleMask_ else id
      open = if gated then void (tryPutMVar (parkedGate parked) ()) else pure ()
  outcome ←
    try @SomeException . inBounds $
      withForkedIn scope open (hold (park parked)) $ \_ _ → endBody ending (reached parked)
  endedAs ending outcome `shouldBe` True
  judged parked (Just Unbound)

-- | The launcher thread of the launch-interruption example: a launch of a long-lived child, observed as soon as the child exists,
-- run on a thread of the given kind of scope, and the body that interrupts it.
withLauncher ∷ Scope → (Child.Owned → ThreadId → MVar (Either SomeException Child.Launched) → IO a) → IO a
withLauncher scope body = do
  acquired ← newEmptyMVar
  result ← newEmptyMVar
  startIn
    scope
    Unbound
    (pure ())
    (try (Child.launchCommandObserved (putMVar acquired) Child.terminationGrace Nothing 300 "sh" ["-c", "sleep 300"]) >>= putMVar result)
    $ \launcher _ → do
      owned ← readMVar acquired
      body owned launcher result

-- | The launcher's scope ends while the launch runs. The thread has ended, the child is gone, and both readers have finished.
launcherHeld ∷ Scope → Cleanups → Ending → IO Bool
launcherHeld scope cleanups ending = do
  seen ← newIORef Nothing
  let process = readIORef seen
  outcome ←
    try @SomeException . inBounds $
      withLauncher scope $ \owned launcher _ → do
        writeIORef seen (Just (owned, launcher))
        cleanupLater cleanups (void (try (signalProcessGroup sigKILL (Child.ownedPid owned)) ∷ IO (Either IOException ())))
        endBody ending (pure ())
  endedAs ending outcome `shouldBe` True
  process >>= \case
    Nothing → pure False
    Just (owned, launcher) → do
      ended ← hasEnded launcher
      readers ← atomically (sequence (Child.ownedReadersFinished owned))
      gone ← either (\(_ ∷ IOException) → True) (const False) <$> try (signalProcess nullSignal (Child.ownedPid owned))
      pure (ended && and readers && gone)

-- | The cleanup a control registers for the unowned thread it leaves, run on a thread of its own and cancelled while its kill
-- is blocked: the worker is held where only its own unmasking can receive the kill, so the cleanup blocks in @killThread@, the
-- cancellation is aimed at it there, and only then is the worker let go. A cleanup that is not interruptible defers the
-- cancellation until it has stopped and joined the worker (which then has ended); an interruptible one takes the cancellation
-- in the blocked kill, is abandoned, and never sends the kill, so the worker goes on to the wait only the kill can end.
cleanupCancelled ∷ (IO () → IO ()) → IO Bool
cleanupCancelled protect = do
  cleanups ← newCleanups
  who ← newEmptyMVar
  held ← newEmptyMVar
  gate ← newEmptyMVar
  never ← newEmptyMVar ∷ IO (MVar ())
  result ← newEmptyMVar
  -- The worker's wait at the end is reachable from this scenario's frame until it has judged, so the runtime does not end the
  -- worker as deadlocked; it is then let go whatever happened.
  ( do
      startIn (unownedScopeProtecting protect cleanups) Unbound (pure ()) (myThreadId >>= putMVar who >> putMVar held () >> uninterruptibleMask_ (readMVar gate) >> readMVar never) $ \_ _ →
        readMVar held
      worker ← readMVar who
      startIn ownedScope Unbound (pure ()) (try @SomeException (runCleanups cleanups) >>= putMVar result) $ \runner runnerEnded → do
        blockedKill ← awaitBlockedSending runner
        blockedKill `shouldBe` True
        startIn ownedScope Unbound (pure ()) (throwTo runner UserInterrupt) $ \canceller _ → do
          -- Deferred (the thrower blocks) when the cleanup cannot be interrupted; taken at once (the thrower ends) when it can.
          void (awaitBlockedSending canceller)
          putMVar gate ()
          runnerEnded
          readMVar result >>= (`shouldBe` True) . endedAs Cancelled
        hasEnded worker
    )
    `finally` void (tryPutMVar never ())
