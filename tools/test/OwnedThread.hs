-- | Hspec coverage for the shared owned-thread facility and the orchestrations built on it (#584).
--
-- "Test.Support.Owned" is the one way a test starts a helper thread: however the scope that needed the thread ends, the thread
-- has ended and been joined before the scope returns. These examples cover every way a scope can end with a thread parked at a
-- gate (a normal return, an exception from the body, a timeout of the example, and a cancellation delivered to the calling
-- thread while the thread is starting and while it is parked), a thread that ended on its own, the release that an
-- interruption cannot abandon, and the interruptibility the body runs with. They are device-free and deterministic: every wait
-- is a gate or an MVar, no example sleeps, and a bound exists only to keep a stuck example from hanging the run.
--
-- /Negative controls./ Each way of ending is run twice with the same judgement, once through the facility and once through a
-- deliberately unowned start ('unownedScope'): the judgement must hold for the first and fail for the second, so an example
-- that could not tell an owned start from an unowned one cannot pass. A control records its failed judgement first and then
-- stops and joins its workers independently, so it neither leaves a thread behind nor fails by leaking into a later example.
--
-- The orchestrations are exercised the way the repaired native sites use them. 'Test.Support.Cancel' is the cancellation the two
-- helpers in @run-native-test@'s @Library@ examples deliver (after the command has begun; after the caller is blocked sending
-- its end), and 'Test.Support.Parked' is the parked-release orchestration of its @ChildSpec@; the workers they run here are
-- test-side stand-ins with the same release shape, because this suite imports neither another suite's specification modules nor
-- the full-product run library. The real child helper runs under the same orchestration in @run-native-test@.
module OwnedThread (spec) where

import Control.Concurrent (ThreadId, forkIOWithUnmask, forkOS, getNumCapabilities, isCurrentThreadBound, killThread, myThreadId, threadCapability, throwTo, yield)
import Control.Concurrent.MVar (MVar, newEmptyMVar, putMVar, readMVar, takeMVar, tryPutMVar, tryReadMVar)
import Control.Exception
  ( AsyncException (ThreadKilled, UserInterrupt)
  , Exception
  , ExceptionWithContext (ExceptionWithContext)
  , MaskingState (MaskedInterruptible, MaskedUninterruptible, Unmasked)
  , SomeException
  , catch
  , finally
  , fromException
  , getMaskingState
  , interruptible
  , mask
  , mask_
  , throwIO
  , try
  , tryWithContext
  , uninterruptibleMask_
  )
import Control.Monad (forM, forM_, void, when, (>=>))
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef, writeIORef)
import Data.Foldable (for_)
import GHC.IO (unsafeUnmask)
import Data.List (isInfixOf)
import Data.Maybe (isJust)
import GHC.Conc (ThreadStatus (ThreadBlocked, ThreadDied, ThreadFinished), threadStatus)
import System.Directory (doesFileExist)
import System.Timeout (timeout)
import Test.Hspec (Spec, describe, it, pendingWith, shouldBe, shouldSatisfy)
import Test.HUnit.Lang (HUnitFailure (HUnitFailure), FailureReason (Reason))
import Test.Support.Bounded (bounded)
import Test.Support.Cancel (awaitBlockedSending, withCancellationAfter, withCancellationWhenBlocked)
import Test.Support.Owned (withOwnedBoundThread, withOwnedBoundThreadOpening, withOwnedThread, withOwnedThreadOn, withOwnedThreadOpening, withOwnedThreadOpeningOn)
import Test.Support.Parked (ParkBounds (..), defaultParkBounds, parkedRelease)

-- | The failure an example raises from a body, told apart from every other.
data Boom = Boom
  deriving (Eq, Show)

instance Exception Boom

-- | How a scope that started a helper is made to end.
data Ending = Returns | Raises | TimesOut | CancelledStarting | CancelledParked
  deriving (Eq, Show)

endings ∷ [(String, Ending)]
endings =
  [ ("returns normally", Returns)
  , ("raises from its body", Raises)
  , ("is timed out", TimesOut)
  , ("is cancelled while the thread is starting", CancelledStarting)
  , ("is cancelled while the thread is parked", CancelledParked)
  ]

-- | A way to start a thread for the length of a body: the facility, or an unowned start the controls compare it with.
type Scope = IO () → (ThreadId → IO () → IO ()) → IO ()

-- | What an example watches of one worker.
data Probe = Probe
  { probeParked ∷ !(MVar ())
  -- ^ Filled when the worker reached its gate.
  , probeGate ∷ !(MVar ())
  -- ^ The gate the worker waits at; no example opens it, so only a kill or a cancellation ends the worker.
  , probeThread ∷ !(MVar ThreadId)
  -- ^ The worker's own thread, filled by the worker as its first step: the example judges that thread, never the worker's
  -- say-so, so a worker killed before it ran anything is still judged.
  , probeBound ∷ !(MVar Bool)
  -- ^ Whether the worker's thread was an OS-bound thread, filled with 'probeThread'.
  }

newProbe ∷ IO Probe
newProbe = Probe <$> newEmptyMVar <*> newEmptyMVar <*> newEmptyMVar <*> newEmptyMVar

-- | The worker's first step: say which thread it is, and whether it is bound.
recordSelf ∷ Probe → IO ()
recordSelf probe = do
  myThreadId >>= void . tryPutMVar (probeThread probe)
  isCurrentThreadBound >>= void . tryPutMVar (probeBound probe)

-- | The worker: say which thread it is, say it is parked, wait at the gate.
parkedWorker ∷ Probe → IO ()
parkedWorker probe = recordSelf probe >> putMVar (probeParked probe) () >> readMVar (probeGate probe)

-- | The worker that takes a kill and goes back to waiting at its gate: only the gate's opening ends it.
stubbornWorker ∷ Probe → IO ()
stubbornWorker probe =
  (recordSelf probe >> putMVar (probeParked probe) () >> readMVar (probeGate probe))
    `catch` \(_ ∷ AsyncException) → readMVar (probeGate probe)

-- | The judgement the facility makes true: the worker's thread has ended, and been joined, when the scope returns. A thread
-- that is blocked has not ended; one that ended is finished, or is running its last steps after announcing its end, which the
-- poll yields to (a count of yields, never a duration, so a thread that never ends gives up the same way on any machine).
endedAfterScope ∷ Probe → IO Bool
endedAfterScope = tryReadMVar . probeThread >=> maybe (pure False) joined

joined ∷ ThreadId → IO Bool
joined thread = go (100000 ∷ Int)
  where
    go 0 = pure False
    go remaining =
      threadStatus thread >>= \case
        ThreadFinished → pure True
        ThreadDied → pure True
        ThreadBlocked _ → pure False
        _ → yield >> go (remaining - 1)

-- | A thread a negative control started without ownership, with the wait for its end and whatever must be let go before it can
-- end (a gate its unwinding waits at), so the control can stop and join it independently of its own assertions.
data Unowned = Unowned ThreadId (MVar ()) (IO ())

-- | A deliberately unowned start, the negative controls' only one: it starts the thread, announces its end however it ended,
-- and registers no stop-and-join. Every thread it starts is recorded so the control can stop and join it independently
-- afterwards. The start is masked and announces its end so that this cleanup can always join the thread, even one it kills
-- before it ran anything (a start without that would leave the cleanup waiting for an announcement that never comes): the
-- defect the controls model is the missing stop-and-join of the scope, not an unannounced end.
unownedScope ∷ IORef [Unowned] → Scope
unownedScope started action body = do
  (thread, done) ← startUnowned started (pure ()) action
  body thread (readMVar done)

startUnowned ∷ IORef [Unowned] → IO () → IO () → IO (ThreadId, MVar ())
startUnowned started letGo action = mask_ $ do
  done ← newEmptyMVar
  thread ← forkIOWithUnmask $ \unmask → unmask action `finally` putMVar done ()
  atomicModifyIORef' started (\known → (Unowned thread done letGo : known, ()))
  pure (thread, done)

-- | 'unownedScope' for an OS-bound thread: the control for the bound start is the plain @forkOS@ the suites used before the
-- facility offered one. Its start is, like 'startUnowned', announced and masked so that the cleanup can always join it.
unownedBoundScope ∷ IORef [Unowned] → Scope
unownedBoundScope started action body = do
  (thread, done) ← startUnownedBound started action
  body thread (readMVar done)

startUnownedBound ∷ IORef [Unowned] → IO () → IO (ThreadId, MVar ())
startUnownedBound started action = uninterruptibleMask_ $ do
  done ← newEmptyMVar
  -- @forkOS@ waits, interruptibly even under @mask_@, for the new OS thread to report itself; the start and its registration for
  -- the rescue are uninterruptible, and the thread runs the action unmasked as a plain @forkOS@ from an unmasked caller does.
  thread ← forkOS (unsafeUnmask action `finally` putMVar done ())
  atomicModifyIORef' started (\known → (Unowned thread done (pure ()) : known, ()))
  pure (thread, done)

-- | Stop and join every thread an unowned control started, even if an assertion before it failed.
reapUnowned ∷ IORef [Unowned] → IO ()
reapUnowned started = uninterruptibleMask_ $ do
  known ← readIORef started
  forM_ known $ \(Unowned thread done letGo) → letGo >> killThread thread >> readMVar done

-- | End the scope the way the ending says, running the scope on the parked worker. The outcome of every ending is asserted as
-- it is raised, so an example never passes because the wrong thing happened.
runEnding ∷ Scope → (Probe → IO ()) → Probe → Ending → IO ()
runEnding scope worker probe ending = case ending of
  Returns → scope (worker probe) (\_ _ → readMVar (probeParked probe))
  Raises → do
    outcome ← try @Boom (scope (worker probe) (\_ _ → readMVar (probeParked probe) >> throwIO Boom))
    outcome `shouldBe` Left Boom
  TimesOut → do
    outcome ← timeout 1000 (scope (worker probe) (\_ _ → readMVar (probeParked probe) >> holdUntilTimedOut))
    outcome `shouldBe` Nothing
  CancelledStarting → do
    caller ← myThreadId
    outcome ← try @AsyncException (bounded (scope (recordSelf probe >> throwTo caller UserInterrupt >> worker probe) (\_ _ → holdUntilTimedOut)))
    outcome `shouldBe` Left UserInterrupt
  CancelledParked → do
    outcome ← try @AsyncException (bounded (withCancellationAfter (readMVar (probeParked probe)) (pure ()) (scope (worker probe) (\_ _ → holdUntilTimedOut))))
    outcome `shouldBe` Left UserInterrupt

-- | Wait where only the example's own end can reach it. The wait is bounded by the caller's @timeout@ or 'bounded', which also
-- keeps the waiting thread reachable so the runtime does not end it as deadlocked.
holdUntilTimedOut ∷ IO ()
holdUntilTimedOut = newEmptyMVar >>= \hold → readMVar hold `finally` void (tryPutMVar hold ())

-- | The target of the cancellation examples (#610): inside an uninterruptible step it announces itself, waits for the sender to
-- be published (@Nothing@ when the scope ended before there was one, so nothing is waited for) and for that sender to be seen
-- blocked delivering, leaves the step, and does an effect. Then it waits for a cancellation, which always arrives (the sender's,
-- or the scope's kill), so every scenario ends the same way whatever happened before.
steppedTarget ∷ MVar (Maybe ThreadId) → MVar () → MVar () → MVar (Either AsyncException ()) → IO ()
steppedTarget senderSlot entered effect ended = do
  let spinUntilCancelled ∷ IO ()
      spinUntilCancelled = yield >> spinUntilCancelled
  outcome ← try @AsyncException $ do
    uninterruptibleMask_ (putMVar entered () >> readMVar senderSlot >>= maybe (pure ()) (void . awaitBlockedSending))
    putMVar effect ()
    spinUntilCancelled
  putMVar ended outcome

-- | One cancellation aimed at a running target (#610), the target and its sender both pinned to one capability. Answers whether
-- the target's effect ran, that is whether the cancellation was /not/ yet raised in it when it left its step. The sender is
-- started once the target is inside its step, so a cancellation that reached it earlier could not be told from one that
-- arrived late. The target's scope opens @senderSlot@ with @Nothing@ in its release (an idempotent, non-blocking opening), so
-- a scope that ends before the sender is published still joins the target.
--
-- With @decoyed@ the sender is aimed at a decoy thread (held uninterruptibly at a gate its scope opens) instead of the target:
-- the sender is then seen blocked delivering although nothing is pending against the target. This is the negative control, and
-- it is deterministic: it shows that the answer /can/ be @True@, so a pinned run answering @False@ is not vacuous.
effectBeforeCancellation ∷ Bool → IO Bool
effectBeforeCancellation decoyed = do
  senderSlot ← newEmptyMVar
  entered ← newEmptyMVar
  effect ← newEmptyMVar
  ended ← newEmptyMVar
  decoyEntered ← newEmptyMVar
  decoyGate ← newEmptyMVar
  let decoy = uninterruptibleMask_ (putMVar decoyEntered () >> readMVar decoyGate)
  withOwnedThreadOpeningOn 0 (void (tryPutMVar senderSlot Nothing)) (steppedTarget senderSlot entered effect ended) $ \targetThread _ → do
    takeMVar entered
    withOwnedThreadOpeningOn 0 (void (tryPutMVar decoyGate ())) decoy $ \decoyThread _ → do
      takeMVar decoyEntered
      withOwnedThreadOn 0 (throwTo (if decoyed then decoyThread else targetThread) ThreadKilled) $ \sender _ → do
        putMVar senderSlot (Just sender)
        -- Aimed at the decoy nothing cancels the target; the example does, once the effect has run.
        when decoyed (readMVar effect >> killThread targetThread)
        takeMVar ended >>= (`shouldBe` Left ThreadKilled)
  isJust <$> tryReadMVar effect

spec ∷ Spec
spec = describe "the shared owned-thread facility (Test.Support.Owned)" $ do
  describe "a thread parked at a gate, whichever way its scope ends" $
    for_ endings $ \(label, ending) → do
      it ("has ended and been joined when the scope " <> label) $ do
        probe ← newProbe
        runEnding withOwnedThread parkedWorker probe ending
        endedAfterScope probe >>= (`shouldBe` True)

      it ("negative control: a deliberately unowned start leaves the thread parked when the scope " <> label) $ do
        started ← newIORef []
        probe ← newProbe
        (do
            runEnding (unownedScope started) parkedWorker probe ending
            -- The judgement is made about a thread the scope left, and only then does anything independent touch the worker:
            -- the failed judgement is recorded before the cleanup.
            judgement ← endedAfterScope probe
            judgement `shouldBe` False)
          `finally` (reapUnowned started >> void (tryPutMVar (probeGate probe) ()))
        endedAfterScope probe >>= (`shouldBe` True)

  describe "a thread held at a gate that it keeps waiting at after a kill, whichever way its scope ends" $
    for_ endings $ \(label, ending) →
      it ("has ended and been joined when the scope " <> label <> ", because the scope opens the gate itself before it joins") $ do
        probe ← newProbe
        -- Registered with the start (withOwnedThreadOpening), so a cancellation delivered as the body begins, before any
        -- handler of the body exists, still finds the gate opened.
        runEnding (withOwnedThreadOpening (void (tryPutMVar (probeGate probe) ()))) stubbornWorker probe ending
        endedAfterScope probe >>= (`shouldBe` True)

  describe "an OS-bound thread parked at a gate, whichever way its scope ends (#593)" $
    for_ endings $ \(label, ending) → do
      it ("is bound, has ended and been joined when the scope " <> label) $ do
        probe ← newProbe
        runEnding withOwnedBoundThread parkedWorker probe ending
        endedAfterScope probe >>= (`shouldBe` True)
        tryReadMVar (probeBound probe) >>= (`shouldBe` Just True)

      it ("negative control: a plain forkOS start leaves the bound thread parked when the scope " <> label) $ do
        started ← newIORef []
        probe ← newProbe
        (do
            runEnding (unownedBoundScope started) parkedWorker probe ending
            judgement ← endedAfterScope probe
            judgement `shouldBe` False)
          `finally` (reapUnowned started >> void (tryPutMVar (probeGate probe) ()))
        endedAfterScope probe >>= (`shouldBe` True)

  describe "an OS-bound thread held at a gate that it keeps waiting at after a kill (#593)" $
    for_ endings $ \(label, ending) →
      it ("has ended and been joined when the scope " <> label <> ", because the scope opens the gate itself before it joins") $ do
        probe ← newProbe
        runEnding (withOwnedBoundThreadOpening (void (tryPutMVar (probeGate probe) ()))) stubbornWorker probe ending
        endedAfterScope probe >>= (`shouldBe` True)

  describe "the boundness of the two starts (#593)" $ do
    it "an owned unbound start is not bound, and an owned bound start is" $ do
      unbound ← newEmptyMVar
      bound ← newEmptyMVar
      withOwnedThread (isCurrentThreadBound >>= putMVar unbound) (\_ awaitEnd → awaitEnd)
      withOwnedBoundThread (isCurrentThreadBound >>= putMVar bound) (\_ awaitEnd → awaitEnd)
      (,) <$> readMVar unbound <*> readMVar bound >>= (`shouldBe` (False, True))

    it "a cancellation already pending when the bound start returns from its acquisition ends the scope with the worker joined" $ do
      -- The cancellation is sent while the caller is masked and received only at the body's first interruptible wait, so it is
      -- pending across the whole acquisition: a start whose own wait for the new OS thread were interruptible could take it
      -- there and abandon a thread that exists. The sender is known to be blocked in its throwTo before the start begins.
      probe ← newProbe
      caller ← myThreadId
      outcome ← try @AsyncException . bounded . mask_ $
        withOwnedThread (throwTo caller UserInterrupt) $ \sender _ → do
          bounded (awaitBlockedSending sender) >>= (`shouldBe` True)
          withOwnedBoundThread (parkedWorker probe) (\_ _ → readMVar (probeParked probe) >> holdUntilTimedOut)
      outcome `shouldBe` Left UserInterrupt
      endedAfterScope probe >>= (`shouldBe` True)

    it "a bound start's body runs with the interruptibility of the caller restored" $ do
      let stateInBody = withOwnedBoundThread (pure ()) (\_ _ → getMaskingState)
      unmasked ← stateInBody
      masked ← mask_ stateInBody
      uninterruptible ← uninterruptibleMask_ stateInBody
      (unmasked, masked, uninterruptible) `shouldBe` (Unmasked, MaskedInterruptible, MaskedUninterruptible)

    it "the thread a bound start runs the action on is unmasked" $ do
      state ← newEmptyMVar
      withOwnedBoundThread (getMaskingState >>= putMVar state) (\_ awaitEnd → awaitEnd)
      readMVar state >>= (`shouldBe` Unmasked)

  describe "the negative controls' rescue (#593)" $ do
    it "registers a bound worker for the rescue even when a cancellation is pending as the control starts it" $ do
      started ← newIORef []
      probe ← newProbe
      caller ← myThreadId
      -- The example's own rescue is independent of the rescue under test and runs on every way out of the example.
      ( do
          outcome ← try @AsyncException . bounded . mask_ $
            withOwnedThread (throwTo caller UserInterrupt) $ \sender _ → do
              bounded (awaitBlockedSending sender) >>= (`shouldBe` True)
              unownedBoundScope started (parkedWorker probe) (\_ _ → readMVar (probeParked probe) >> holdUntilTimedOut)
          outcome `shouldBe` Left UserInterrupt
          reapUnowned started
          endedAfterScope probe >>= (`shouldBe` True)
        )
        `finally` (reapUnowned started >> void (tryPutMVar (probeGate probe) ()))

    it "completes the rescue's stop-and-join when a cancellation is pending while it runs" $ do
      started ← newIORef []
      probe ← newProbe
      caller ← myThreadId
      rescued ← newIORef False
      ( do
          unownedScope started (parkedWorker probe) (\_ _ → readMVar (probeParked probe))
          _ ← try @AsyncException . bounded . mask_ $
            withOwnedThread (throwTo caller UserInterrupt) $ \sender _ → do
              bounded (awaitBlockedSending sender) >>= (`shouldBe` True)
              reapUnowned started
              endedAfterScope probe >>= writeIORef rescued
          -- The scope's release ends the sender, so the cancellation need not be delivered at all; what matters is that it was
          -- pending while the rescue ran and did not abandon it.
          readIORef rescued >>= (`shouldBe` True)
        )
        `finally` (reapUnowned started >> void (tryPutMVar (probeGate probe) ()))

  describe "a thread that ended on its own" $ do
    it "is joined harmlessly, the body may begin after it finished, and the wait can be repeated" $ do
      probe ← newProbe
      finishedOnItsOwn ← newEmptyMVar
      withOwnedThread (recordSelf probe `finally` putMVar finishedOnItsOwn ()) $ \_ awaitEnd → do
        readMVar finishedOnItsOwn
        awaitEnd
        awaitEnd
      endedAfterScope probe >>= (`shouldBe` True)

    it "is not mistaken for a leak by a scope that returns before looking at it" $ do
      probe ← newProbe
      -- The kill may arrive before the thread ran anything; the scope has joined it either way.
      withOwnedThread (recordSelf probe) (\thread _ → void (tryPutMVar (probeThread probe) thread))
      endedAfterScope probe >>= (`shouldBe` True)

  describe "a thread pinned to a capability (withOwnedThreadOn, withOwnedThreadOpeningOn)" $ do
    for_ endings $ \(label, ending) → do
      it ("has ended and been joined when the scope " <> label) $ do
        probe ← newProbe
        runEnding (withOwnedThreadOn 0) parkedWorker probe ending
        endedAfterScope probe >>= (`shouldBe` True)

      it ("has ended and been joined when the scope " <> label <> ", because the scope opens the gate itself before it joins") $ do
        probe ← newProbe
        runEnding (withOwnedThreadOpeningOn 0 (void (tryPutMVar (probeGate probe) ()))) stubbornWorker probe ending
        endedAfterScope probe >>= (`shouldBe` True)

    it "runs the thread on the capability asked for, pinned there, and with the caller's interruptibility not inherited" $ do
      capabilities ← getNumCapabilities
      for_ [0 .. capabilities - 1] $ \capability → do
        placed ← newEmptyMVar
        withOwnedThreadOn capability (myThreadId >>= threadCapability >>= \place → getMaskingState >>= putMVar placed . (,) place) $ \_ awaitEnd →
          awaitEnd
        readMVar placed >>= (`shouldBe` ((capability, True), Unmasked))

    it "has a cancellation pending against a masked target on the same capability as soon as its sender is seen blocked, on more than one capability" $ do
      -- The property the pin exists for (#610): the sender and the target share a capability, so the target's queue holds the
      -- exception before the sender is recorded as blocked, and a target that leaves its uninterruptible step after seeing
      -- the sender blocked has the exception raised in it before its next effect, every time.
      capabilities ← getNumCapabilities
      (capabilities >= 2) `shouldSatisfy` id
      ran ← forM [1 .. 1000 :: Int] $ \_ → bounded (effectBeforeCancellation False)
      length (filter id ran) `shouldBe` 0

    it "negative control: a sender seen blocked delivering to something else leaves nothing pending against the target, which runs its next effect" $
      -- Deterministic: the judgement above is not vacuous, because the same scenario answers True when the sender's exception is
      -- not aimed at the target. (That an unpinned pair can also answer True is a race, kept as stress evidence in the PR, not
      -- asserted here.)
      bounded (effectBeforeCancellation True) >>= (`shouldBe` True)

    it "joins the target when the scope is cancelled after the target entered its step and before the sender is published" $ do
      senderSlot ← newEmptyMVar
      entered ← newEmptyMVar
      effect ← newEmptyMVar
      ended ← newEmptyMVar
      -- The target waits for a sender that never comes; the scope's release publishes @Nothing@ for it before it kills and joins.
      outcome ← try @AsyncException $
        bounded $
          withOwnedThreadOpeningOn 0 (void (tryPutMVar senderSlot Nothing)) (steppedTarget senderSlot entered effect ended) $ \_ _ → do
            takeMVar entered
            myThreadId >>= \caller → throwTo caller UserInterrupt
      outcome `shouldBe` Left UserInterrupt
      tryReadMVar ended >>= (`shouldBe` Just (Left ThreadKilled))

  describe "the release" $ do
    it "is not interruptible: a cancellation that arrives while it waits for the thread does not abandon the join" $ do
      -- The worker takes its kill and then keeps the release waiting at a second gate until it is let go. While the join
      -- waits, a cancellation is sent to the calling thread; it must not end the join, so the worker finishes strictly before
      -- the scope is left. The worker is let go only once the cancellation is being sent, which the runtime reports as the
      -- sender being blocked (the calling thread, in its uninterruptible release, cannot yet receive it); had the join been
      -- interruptible the sender would have finished instead and the worker would never be let go.
      order ← newIORef ([] ∷ [String])
      holdGate ← newEmptyMVar
      holding ← newEmptyMVar
      killed ← newEmptyMVar
      letGo ← newEmptyMVar
      caller ← myThreadId
      let note line = atomicModifyIORef' order (\known → (known <> [line], ()))
          stubborn = (putMVar holding () >> readMVar holdGate) `catch` \(_ ∷ AsyncException) → putMVar killed () >> readMVar letGo >> note "worker finished"
      outcome ← try @AsyncException $
        bounded $
          withOwnedThread (readMVar killed >> throwTo caller UserInterrupt) $ \sender _ →
            withOwnedThread (awaitBlockedSending sender >>= \sending → when sending (void (tryPutMVar letGo ()))) $ \_ _ →
              -- The inner scope's release is the one the cancellation arrives in: its body returns at once.
              -- It returns once the worker is holding, so the kill is delivered to a worker that can take it.
              withOwnedThread stubborn (\_ _ → readMVar holding)
                -- The cancellation is received once the release has let the caller go: the caller waits for it here, inside
                -- the scopes that own the sender, which would otherwise end it with the scope.
                >> holdUntilTimedOut
      note "scope left"
      void (tryPutMVar holdGate () >> tryPutMVar letGo ())
      readIORef order >>= (`shouldBe` ["worker finished", "scope left"])
      outcome `shouldBe` Left UserInterrupt

  describe "the body" $ do
    it "runs with the interruptibility of the caller restored" $ do
      inside ← newEmptyMVar
      let stateInBody = withOwnedThread (pure ()) (\_ _ → getMaskingState)
      unmasked ← stateInBody
      masked ← mask_ stateInBody
      uninterruptible ← uninterruptibleMask_ stateInBody
      putMVar inside ()
      (unmasked, masked, uninterruptible) `shouldBe` (Unmasked, MaskedInterruptible, MaskedUninterruptible)

  describe "its definition" $
    it "uses no timed wait and depends on base alone" $ do
      let path = "tools/test-support/src/Test/Support/Owned.hs"
          startsWith prefix line = take (length prefix) line == prefix
      present ← doesFileExist path
      if not present
        then pendingWith "the facility's source is another package's, which a source distribution does not carry"
        else do
          source ← readFile path
          let imports = [line | line ← lines source, startsWith "import " line]
          -- base alone: the Control modules, and the one GHC.IO import the bound start unmasks its action with (#593)
          imports `shouldSatisfy` all (\line → startsWith "import Control." line || line == "import GHC.IO (unsafeUnmask)")
          source `shouldSatisfy` (not . ("threadDelay" `isInfixOf`))

  describe "the cancellation helper behind the first Library.hs helper (Test.Support.Cancel.withCancellationAfter)" $ do
    for_ [("returns normally", Returns), ("raises from its body", Raises)] $ \(label, ending) → do
      it ("leaves no helper waiting when the example " <> label <> " before the command begins") $ do
        helper ← newEmptyMVar
        never ← newEmptyMVar
        runCancelling ending (\body → withCancellationAfter (waitingFor helper never) (pure ()) (readMVar helper >> body))
        judged ← readMVar helper >>= joined
        void (tryPutMVar never ())
        judged `shouldBe` True

      it ("negative control: an unowned helper is still waiting when the example " <> label) $ do
        started ← newIORef []
        helper ← newEmptyMVar
        never ← newEmptyMVar
        (do
            runCancelling ending (\body → unownedHelper started (waitingFor helper never) >> readMVar helper >> body)
            judged ← readMVar helper >>= joined
            judged `shouldBe` False)
          `finally` (reapUnowned started >> void (tryPutMVar never ()))
        readMVar helper >>= joined >>= (`shouldBe` True)

    it "cancels the example once the command has begun, and then lets the command go on" $ do
      cancelledAfterScenario >>= (`shouldBe` (Left UserInterrupt, Just ()))

  describe "the cancellation helper behind the second Library.hs helper (Test.Support.Cancel.withCancellationWhenBlocked)" $ do
    it "cancels a caller blocked sending its end to a held thread, and then lets the held thread go" $ do
      cancelledWhenBlockedScenario >>= (`shouldBe` (Left UserInterrupt, Just ()))

    it "still opens the gate after delivering the cancellation, however often the caller's unwinding races the helper, on more than one capability" $ do
      -- The caller's release kills the helper as soon as the cancellation lands, so a helper that could be killed between the
      -- delivery and the gate opening skips it on some runs: this repeats both scenarios often enough to see that happen.
      capabilities ← getNumCapabilities
      (capabilities >= 2) `shouldSatisfy` id
      for_ [1 .. 1000 :: Int] $ \_ → do
        cancelledAfterScenario >>= (`shouldBe` (Left UserInterrupt, Just ()))
        cancelledWhenBlockedScenario >>= (`shouldBe` (Left UserInterrupt, Just ()))

    for_ [("returns normally", Returns), ("raises from its body", Raises)] $ \(label, ending) → do
      it ("leaves no helper running or spinning when the example " <> label <> " before it ever blocks sending") $ do
        helper ← newEmptyMVar
        ended ← newEmptyMVar
        putMVar ended ()
        -- The event has happened, so the helper goes on to wait for the caller to block sending: the wait the example ends.
        runCancelling ending (\body → withCancellationWhenBlocked (recordHelper helper >> readMVar ended) (pure ()) (readMVar helper >> body))
        readMVar helper >>= joined >>= (`shouldBe` True)

      it ("negative control: an unowned helper keeps waiting for the caller to block when the example " <> label) $ do
        started ← newIORef []
        helper ← newEmptyMVar
        ended ← newEmptyMVar
        putMVar ended ()
        caller ← myThreadId
        (do
            runCancelling ending (\body → unownedHelper started (recordHelper helper >> readMVar ended >> void (awaitUnblockedSending caller)) >> readMVar helper >> body)
            readMVar helper >>= joined >>= (`shouldBe` False))
          `finally` (reapUnowned started)

    it "answers False, without spinning, for a thread that ended before it was ever blocked sending" $ do
      done ← newEmptyMVar
      withOwnedThread (putMVar done ()) $ \thread awaitEnd → do
        readMVar done
        awaitEnd
        bounded (awaitBlockedSending thread) >>= (`shouldBe` False)

    it "answers True for a thread blocked in a throwTo that its target cannot yet receive" $ do
      gate ← newEmptyMVar
      target ← newEmptyMVar
      -- The end it is sent is delivered when the region is left; it is taken here so that the thread ends quietly.
      withOwnedThread (uninterruptibleMask_ (putMVar target () >> readMVar gate) `catch` \(_ ∷ AsyncException) → pure ()) $ \held _ → do
        readMVar target
        withOwnedThread (throwTo held UserInterrupt `catch` \(_ ∷ SomeException) → pure ()) $ \sender _ → do
          bounded (awaitBlockedSending sender) >>= (`shouldBe` True)
          putMVar gate ()

  describe "the parked-release orchestration behind ChildSpec (Test.Support.Parked.parkedRelease)" $ do
    it "cancels the worker where its release is parked, lets it finish, and answers the cancellation after the release ran" $ do
      resource ← newResource
      finishGate ← newMVarOpen
      outcome ← parkedRelease defaultParkBounds (standIn resource finishGate (pure ()) (pure ()))
      outcome `shouldSatisfy` cancelled
      released resource >>= (`shouldBe` True)

    it "raises the failure of the helper that ended without reaching its release, with nothing left" $ do
      resource ← newResource
      finishGate ← newMVarOpen
      outcome ← try @HUnitFailure (parkedRelease defaultParkBounds (\_ → standIn resource finishGate (pure ()) (pure ()) (pure ())))
      outcome `shouldSatisfy` failedWith "ended without reaching its release"
      released resource >>= (`shouldBe` True)

    for_ parkedFailures $ \failure → do
      it ("leaves no worker or resource behind when " <> failureLabel failure) $ do
        resource ← newResource
        finishGate ← gateFor failure
        outcome ← try @HUnitFailure (parkedRelease (failureBounds failure) (failureWorker failure resource finishGate))
        outcome `shouldSatisfy` failedWith (failureMessage failure)
        -- What the worker acquired it has released: a worker the scope stopped before it ran anything acquired nothing.
        nothingLeft resource >>= (`shouldBe` True)
        void (tryPutMVar finishGate ())

      it ("negative control: the former unowned orchestration leaves the worker and resource behind when " <> failureLabel failure) $ do
        started ← newIORef []
        resource ← newResource
        finishGate ← gateFor failure
        (do
            outcome ← try @HUnitFailure (unownedParkedRelease started (failureBounds failure) (failureWorker failure resource finishGate))
            outcome `shouldSatisfy` failedWith (failureMessage failure)
            -- The worker, left running, has by now acquired its resource and has not released it. The judgement is made
            -- here, before anything independent stops the worker.
            bounded (readMVar (acquiredFlag resource))
            nothingLeft resource >>= (`shouldBe` False))
          `finally` (reapUnowned started >> void (tryPutMVar finishGate ()))
        nothingLeft resource >>= (`shouldBe` True)

    it "leaves no worker or resource behind when the example is cancelled while the worker's release is parked with the gate closed" $ do
      -- The worker cancels the example at its first park, before it has said it parked, so the example is cancelled while it
      -- waits for the park and the gate is still closed. The release remembers the kill and retries its park, so a gate left
      -- closed by the cancelled example would hold the join for ever: the scope opens it before it joins.
      resource ← newResource
      finishGate ← newMVarOpen
      caller ← myThreadId
      once ← newIORef True
      let first = atomicModifyIORef' once (\fresh → (False, fresh)) >>= \fresh → if fresh then throwTo caller UserInterrupt else pure ()
      outcome ← try @AsyncException (bounded (parkedRelease defaultParkBounds (standIn resource finishGate first (pure ()))))
      outcome `shouldSatisfy` either (== UserInterrupt) (const False)
      released resource >>= (`shouldBe` True)

-- | A failure branch of the orchestration, and how to provoke it.
data ParkedFailure = ParkedFailure
  { failureLabel ∷ String
  , failureMessage ∷ String
  , failureBounds ∷ ParkBounds
  , failureFinishGateOpen ∷ Bool
  -- ^ Whether the worker's release may pass its finish gate. A worker the example must see still releasing is held there.
  , failureWorker ∷ Resource → MVar () → IO () → IO ()
  }

parkedFailures ∷ [ParkedFailure]
parkedFailures =
  [ ParkedFailure
      { failureLabel = "the wait for the release expires while the worker is still in its body"
      , failureMessage = "did not reach its release"
      , failureBounds = ParkBounds 0 (30 * 1000000)
      , failureFinishGateOpen = True
      , failureWorker = \resource finishGate → standIn resource finishGate (pure ()) holdUntilTimedOut
      }
  , ParkedFailure
      { failureLabel = "the wait for the worker to finish expires while it is still releasing"
      , failureMessage = "did not finish within"
      , failureBounds = ParkBounds (30 * 1000000) 0
      , failureFinishGateOpen = False
      , failureWorker = \resource finishGate → standIn resource finishGate (pure ()) (pure ())
      }
  ]

-- | A resource a worker owns, as the child helper owns its process: acquired under mask by the worker, released by the worker's
-- own release however the worker ended.
data Resource = Resource {acquiredFlag ∷ !(MVar ()), releasedFlag ∷ !(MVar ())}

newResource ∷ IO Resource
newResource = Resource <$> newEmptyMVar <*> newEmptyMVar

released ∷ Resource → IO Bool
released = fmap isJust . tryReadMVar . releasedFlag

-- | Nothing the worker acquired is left: what it acquired it released.
nothingLeft ∷ Resource → IO Bool
nothingLeft resource = do
  acquired ← isJust <$> tryReadMVar (acquiredFlag resource)
  releasedNow ← released resource
  pure (not acquired || releasedNow)

-- | The worker's finish gate for a failure branch: open, or closed where the example must see the worker still releasing.
gateFor ∷ ParkedFailure → IO (MVar ())
gateFor failure = if failureFinishGateOpen failure then newMVarOpen else newEmptyMVar

newMVarOpen ∷ IO (MVar ())
newMVarOpen = newEmptyMVar >>= \gate → putMVar gate () >> pure gate

-- | A worker shaped like the child helper: it acquires its resource under mask, runs a body, and releases in a step that
-- remembers a cancellation delivered to it (each attempt of the release runs the action before the park, then the park,
-- interruptibly; the first interrupt ends the attempt, is remembered, and the attempt is retried), then raises what it
-- remembered. A second interrupt is not absorbed: it ends the worker, because the release here waits at the finish gate, which
-- the child helper's bounded waits do not, and a worker that took every kill would hold its join for ever. After the park the
-- release waits at the finish gate. The resource is released however the release ended, so a worker killed anywhere in it still
-- frees what it owns. Arguments: the resource, the finish gate, the action before each park, the body, the park (the
-- orchestration's).
standIn ∷ Resource → MVar () → IO () → IO () → IO () → IO ()
standIn resource finishGate beforePark body park = mask $ \restore → do
  putMVar (acquiredFlag resource) ()
  outcome ← tryWithContext @SomeException (restore body)
  let attempt remembered =
        (interruptible (beforePark >> park) >> pure remembered)
          `catch` \interruption → case remembered of
            Nothing → attempt (Just (interruption ∷ AsyncException))
            Just _ → throwIO interruption
  remembered ←
    ( do
        remembered ← attempt Nothing
        interruptible (readMVar finishGate)
        pure remembered
    )
      `finally` putMVar (releasedFlag resource) ()
  case (remembered, outcome) of
    (Just interruption, _) → throwIO interruption
    (Nothing, Left failure) → throwIO failure
    (Nothing, Right ()) → pure ()

cancelled ∷ Either (ExceptionWithContext SomeException) () → Bool
cancelled = either (\(ExceptionWithContext _ failure) → fromException failure == Just UserInterrupt) (const False)

failedWith ∷ String → Either HUnitFailure a → Bool
failedWith needle = \case
  Left (HUnitFailure _ (Reason message)) → needle `isInfixOf` message
  _ → False

-- | End the example the way the ending says around a helper scope, asserting the outcome of every ending.
runCancelling ∷ Ending → (IO () → IO ()) → IO ()
runCancelling ending scope = case ending of
  Raises → do
    outcome ← try @Boom (scope (throwIO Boom))
    outcome `shouldBe` Left Boom
  _ → scope (pure ())

-- | The event a helper waits for in these examples, which never arrives: the helper first says which thread it is.
waitingFor ∷ MVar ThreadId → MVar () → IO ()
waitingFor helper never = recordHelper helper >> readMVar never

recordHelper ∷ MVar ThreadId → IO ()
recordHelper helper = myThreadId >>= void . tryPutMVar helper

-- | The wait the unowned control's helper makes: the caller never blocks sending in these examples, so it only ends when the
-- caller has, and an unowned helper outlives the example.
awaitUnblockedSending ∷ ThreadId → IO Bool
awaitUnblockedSending = awaitBlockedSending

-- | An unowned helper, as the control for the cancellation helpers: started and never stopped.
unownedHelper ∷ IORef [Unowned] → IO () → IO ()
unownedHelper started action = unownedScope started action (\_ _ → pure ())

-- | The orchestration this module's parked-release examples replace, kept as the negative control: the same steps and bounds
-- with the worker started by a bare @forkIO@ and nothing that stops or joins it, and the gate opened only on the way through.
unownedParkedRelease ∷ IORef [Unowned] → ParkBounds → (IO () → IO ()) → IO (Either (ExceptionWithContext SomeException) ())
unownedParkedRelease started bounds worker = do
  parked ← newEmptyMVar
  gate ← newEmptyMVar
  finished ← newEmptyMVar
  let park = void (tryPutMVar parked ()) >> readMVar gate
  (thread, _) ← startUnowned started (void (tryPutMVar gate ())) (tryWithContext @SomeException (worker park) >>= putMVar finished)
  reached ← timeout (boundReach bounds) (readMVar parked)
  case reached of
    Just () → pure ()
    Nothing → failWith ("the helper did not reach its release within " <> show (boundReach bounds `div` 1000000) <> " seconds")
  throwTo thread UserInterrupt
  putMVar gate ()
  timeout (boundFinish bounds) (readMVar finished)
    >>= maybe (failWith ("the helper did not finish within " <> show (boundFinish bounds `div` 1000000) <> " seconds")) pure
  where
    failWith message = throwIO (HUnitFailure Nothing (Reason message))

-- | A caller cancelled once its command has begun, with the gate the cancellation is to be followed by opening: how the
-- example ended, and whether the gate was opened by the time the scope returned.
cancelledAfterScenario ∷ IO (Either AsyncException (), Maybe ())
cancelledAfterScenario = do
  began ← newEmptyMVar
  gate ← newEmptyMVar
  outcome ← try @AsyncException $
    bounded $
      withCancellationAfter (takeMVar began) (putMVar gate ()) $ do
        putMVar began ()
        takeMVar gate
        -- Not reached: the cancellation is delivered to this thread before the gate is opened.
        readMVar gate
  opened ← tryReadMVar gate
  pure (outcome, opened)

-- | A caller cancelled while blocked sending its end to a held thread, which only the gate lets go.
cancelledWhenBlockedScenario ∷ IO (Either AsyncException (), Maybe ())
cancelledWhenBlockedScenario = do
  ended ← newEmptyMVar
  gate ← newEmptyMVar
  holding ← newEmptyMVar
  putMVar ended ()
  outcome ← try @AsyncException $
    bounded $
      withCancellationWhenBlocked (readMVar ended) (putMVar gate ()) $
        -- The held thread cannot receive an end until the example lets it go: the caller blocks sending one. It is sent only
        -- once the held thread says it is inside the region that holds it, because on more than one capability a thread
        -- killed before it got there would simply end, and the caller would never block.
        withOwnedThread (uninterruptibleMask_ (putMVar holding () >> readMVar gate)) $ \held _ → readMVar holding >> killThread held
  opened ← tryReadMVar gate
  pure (outcome, opened)
