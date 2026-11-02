-- | The regression examples for the threads this suite's own helpers start (#598): the start-and-wait helper
-- ('Test.Lua.Boundary.Loader.Support.inThread'), a closer parked in a finalizer, and a runner parked in a held call.
--
-- /The judgement./ A helper owns its thread when, however the scope that needed it ends (a failing body, a cancellation), the
-- thread has ended and been joined by the time the scope returns. 'endedAfter' makes that judgement about the threads the
-- example recorded as its own first step, so a thread killed before it ran anything is still judged.
--
-- /The controls./ A judgement that cannot fail proves nothing. Each shape has a negative control that applies the same
-- judgement to the previous, unowned shape: a scope that starts a thread and returns without stopping it. The control
-- reproduces that shape inside an owned outer scope, so it adds no start the ownership guard counts: the outer scope owns the
-- thread, the control records its failed judgement first, and the outer scope then stops and joins whatever the control left,
-- even when an assertion fails, so it leaves nothing for a later example.
--
-- Nothing here sleeps: every wait is a gate, an 'MVar' or a yield, and a bound exists only to keep a stuck example from
-- hanging the run.
module Test.Lua.Ownership (spec) where

import Control.Concurrent (ThreadId, myThreadId, yield)
import Control.Concurrent.MVar (MVar, newEmptyMVar, putMVar, readMVar, takeMVar, tryPutMVar)
import Control.Exception (AsyncException (UserInterrupt), Exception, finally, throwIO, try)
import Control.Monad (forM_, void)
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef, writeIORef)
import GHC.Conc (ThreadStatus (ThreadDied, ThreadFinished), threadStatus)
import Hetoimasia.Scripting.Lua.Bridge (Library (LibraryBase), Vm, chunkName, closeVm, evalChunk)
import Hetoimasia.Scripting.Lua.Internal.Callback (CallbackResult (NoResult), installCallback)
import Hetoimasia.Scripting.Lua.Internal.Vm (Phase (Closed), vmPhase)
import Test.Hspec (Expectation, Spec, describe, expectationFailure, it, shouldBe, shouldReturn)
import Test.Lua.Boundary.Loader.Support (inThread)
import Test.Lua.Support (acquireVm)
import Test.Support.Bounded (bounded)
import Test.Support.Cancel (withCancellationAfter)
import Test.Support.Owned (withOwnedThread, withOwnedThreadOpening)

-- | What an example watches: the threads it judges, and the worker's gates.
data Probe = Probe
  { probeThreads ∷ !(IORef [ThreadId])
  , probeParked ∷ !(MVar ())
  -- ^ Filled when a worker reached its hold.
  , probeGate ∷ !(MVar ())
  -- ^ The gate a worker waits at; no example opens it, so only a kill, a stop or a cancellation ends the worker.
  }

newProbe ∷ IO Probe
newProbe = Probe <$> newIORef [] <*> newEmptyMVar <*> newEmptyMVar

-- | The scope records the thread it started: a thread killed before it ran anything must still be judged, so no thread records
-- itself.
recordThread ∷ Probe → ThreadId → IO ()
recordThread probe thread = atomicModifyIORef' (probeThreads probe) (\held → (held <> [thread], ()))

parkedWorker ∷ Probe → IO ()
parkedWorker probe = putMVar (probeParked probe) () >> readMVar (probeGate probe)

-- | Wait where only the example's own end can reach it.
holdUntilEnded ∷ IO ()
holdUntilEnded = newEmptyMVar >>= \hold → readMVar hold `finally` void (tryPutMVar hold ())

-- | The failure an example raises from a body, told apart from every other.
data Boom = Boom
  deriving (Eq, Show)

instance Exception Boom

-- | Every thread the example recorded has ended and been joined: a finished or died thread, never a blocked one. The poll
-- yields through a thread that has announced its end and is leaving (a count of yields, never a duration).
endedAfter ∷ Probe → IO Bool
endedAfter probe = readIORef (probeThreads probe) >>= \threads → and <$> mapM joined threads

joined ∷ ThreadId → IO Bool
joined thread = go (100000 ∷ Int)
  where
    go 0 = pure False
    go remaining =
      threadStatus thread >>= \case
        ThreadFinished → pure True
        ThreadDied → pure True
        _ → yield >> go (remaining - 1)

-- | The judgement is made about this many threads, so a scope that recorded none cannot pass it.
judged ∷ Probe → Int → Expectation
judged probe expected = (length <$> readIORef (probeThreads probe)) `shouldReturn` expected

-- | How a scope that started a parked thread is made to end.
data Ending = Raises | CancelledParked
  deriving (Eq, Show)

endings ∷ [(String, Ending)]
endings =
  [ ("a failing body", Raises)
  , ("a cancellation while its thread is parked", CancelledParked)
  ]

-- | End the scope the way the ending says, running the body inside it once @parked@ says the scope's thread is parked. The
-- outcome of every ending is asserted as it is raised, so an example never passes because the wrong thing happened.
runEnding ∷ (IO () → IO ()) → IO () → Ending → IO ()
runEnding scope parked = \case
  Raises → do
    outcome ← try @Boom (scope (parked >> throwIO Boom))
    outcome `shouldBe` Left Boom
  CancelledParked → do
    outcome ← try @AsyncException . bounded $ withCancellationAfter parked (pure ()) (scope holdUntilEnded)
    outcome `shouldBe` Left UserInterrupt

-- | The previous, unowned shape: a scope that starts a worker and returns without stopping it. The worker is started by an owned
-- outer scope, so it is stopped and joined whatever the judgement finds; the failed judgement is recorded first and asserted
-- after the outer scope has returned.
leakedAfterScope ∷ Probe → IO Bool
leakedAfterScope probe =
  withOwnedThread (parkedWorker probe) $ \thread _ → do
    recordThread probe thread
    readMVar (probeParked probe)
    -- The scope under test returns here, leaving the worker parked.
    endedAfter probe

spec ∷ Spec
spec = describe "the threads this suite's own helpers start (#598)" $ do
  describe "a start-and-wait helper (inThread)" $ do
    it "ends and joins its thread when the example waiting for it is cancelled while the thread is parked" $ bounded $ do
      probe ← newProbe
      outcome ←
        try @AsyncException . bounded $
          withCancellationAfter (readMVar (probeParked probe)) (pure ()) (inThread (myThreadId >>= recordThread probe >> parkedWorker probe))
      outcome `shouldBe` Left UserInterrupt
      judged probe 1
      endedAfter probe `shouldReturn` True
    it "ends and joins its thread when the thread fails, raising the failure here" $ bounded $ do
      probe ← newProbe
      outcome ← try @Boom (inThread (myThreadId >>= recordThread probe >> throwIO Boom ∷ IO ()))
      outcome `shouldBe` Left Boom
      judged probe 1
      endedAfter probe `shouldReturn` True
    it "is judged a leak when a scope returns without stopping the thread it started (the previous, unowned shape)" $ bounded $ do
      probe ← newProbe
      verdict ← leakedAfterScope probe
      verdict `shouldBe` False

  describe "closers parked in a finalizer" $ do
    -- The first closer is parked in a finalizer that holds `release`; the second waits for the teardown the first is running.
    -- The stop lets the finalizer go, so the teardown completes and both closers can be joined.
    let scope probe vmRef body = do
          vm ← acquireVm [LibraryBase]
          writeIORef vmRef (Just vm)
          entered ← newEmptyMVar
          release ← newEmptyMVar
          installCallback vm "linger" (putMVar entered () >> readMVar release >> pure NoResult) (pure ())
          evalChunk vm (chunkName "finalizer") "guard = setmetatable({}, {__gc = function() linger() end})"
          let letGo = void (tryPutMVar release ())
          withOwnedThreadOpening letGo (closeVm vm) $ \first _ → do
            recordThread probe first
            takeMVar entered
            withOwnedThreadOpening letGo (closeVm vm) $ \second _ → do
              recordThread probe second
              putMVar (probeParked probe) ()
              body
    forM_ endings $ \(label, ending) →
      it ("lets the finalizer go, completes the close and joins both closers on " <> label) $ bounded $ do
        probe ← newProbe
        vmRef ← newIORef (Nothing ∷ Maybe Vm)
        runEnding (scope probe vmRef) (readMVar (probeParked probe)) ending
        judged probe 2
        endedAfter probe `shouldReturn` True
        -- the stop let the finalizer go and joined both closers, so the teardown completed
        readIORef vmRef >>= maybe (expectationFailure "the scope never acquired its VM") (\vm → vmPhase vm `shouldReturn` Closed)
    it "is judged a leak when a scope returns without stopping the closers it started (the previous, unowned shape)" $ bounded $ do
      probe ← newProbe
      verdict ← leakedAfterScope probe
      verdict `shouldBe` False
