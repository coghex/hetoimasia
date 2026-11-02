-- | What the regression examples for the foundation suite's owned-thread helpers share (#597): the endings a scope is made to
-- have while its thread is parked, the judgement that the thread has ended and been joined when the scope returns, and the
-- deliberately unowned start the negative controls compare the helpers with.
--
-- /The judgement./ A helper owns its thread when, however the scope that needed it ends (a failing body, a cancellation), the
-- thread has ended and been joined by the time the scope returns. 'endedAfterScope' makes that judgement about the thread the
-- worker recorded as its own first step, so a thread killed before it ran anything is still judged.
--
-- /The controls./ Each helper's example is run twice with the same judgement: once through the helper, and once through the
-- start the helper replaced ('unownedScope'), which must fail it. A control records its failed judgement first and then stops
-- and joins what it left, outside the scope under test and on every way out, so it leaves nothing for a later example. The
-- raw start sits in the one exempt binding 'startUnowned' (see @tools/validation/owned_starts.json@), registered in the
-- caller's rescue list in the same masked step that starts the thread.
--
-- Nothing here sleeps: every wait is a gate or an MVar, and a bound exists only to keep a stuck example from hanging the run.
module Test.Foundation.OwnedControl
  ( -- * Endings
    Ending (..)
  , endings
  , Boom (..)
  , Scope
  , runEnding
  , holdUntilTimedOut

    -- * The worker and the judgement
  , Probe (..)
  , newProbe
  , recordSelf
  , parkedWorker
  , endedAfterScope
  , joined

    -- * The previous, unowned start
  , Unowned
  , startUnowned
  , unownedScope
  , reapUnowned
  , withRescue
  ) where

import Control.Concurrent (ThreadId, forkIOWithUnmask, killThread, myThreadId, yield)
import Control.Concurrent.MVar (MVar, newEmptyMVar, putMVar, readMVar, tryPutMVar, tryReadMVar)
import Control.Exception
  ( AsyncException (UserInterrupt)
  , Exception
  , finally
  , mask_
  , throwIO
  , try
  , uninterruptibleMask_
  )
import Control.Monad (forM_, void)
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import GHC.Conc (ThreadStatus (ThreadBlocked, ThreadDied, ThreadFinished), threadStatus)
import Test.Hspec (shouldBe)
import Test.Support.Bounded (bounded)
import Test.Support.Cancel (withCancellationAfter)

-- | The failure an example raises from a body, told apart from every other.
data Boom = Boom
  deriving (Eq, Show)

instance Exception Boom

-- | How a scope that started a thread is made to end while the thread is parked.
data Ending = Raises | CancelledParked
  deriving (Eq, Show)

endings ∷ [(String, Ending)]
endings =
  [ ("raises from its body", Raises)
  , ("is cancelled while the thread is parked", CancelledParked)
  ]

-- | A way to start a thread for the length of a body: the helper under test, or the unowned start it replaced. The body is
-- given the thread.
type Scope = IO () → (ThreadId → IO ()) → IO ()

-- | What an example watches of one worker.
data Probe = Probe
  { probeParked ∷ !(MVar ())
  -- ^ Filled when the worker reached its gate.
  , probeGate ∷ !(MVar ())
  -- ^ The gate the worker waits at; no example opens it, so only a kill or a cancellation ends the worker.
  , probeThread ∷ !(MVar ThreadId)
  -- ^ The worker's own thread, recorded by the worker as its first step: the example judges that thread, never the worker's
  -- say-so, so a worker killed before it ran anything is still judged.
  }

newProbe ∷ IO Probe
newProbe = Probe <$> newEmptyMVar <*> newEmptyMVar <*> newEmptyMVar

-- | The worker's first step: say which thread it is.
recordSelf ∷ Probe → IO ()
recordSelf probe = myThreadId >>= void . tryPutMVar (probeThread probe)

-- | The worker: say which thread it is, say it is parked, wait at the gate.
parkedWorker ∷ Probe → IO ()
parkedWorker probe = recordSelf probe >> putMVar (probeParked probe) () >> readMVar (probeGate probe)

-- | Wait where only the example's own end can reach it. The wait is bounded by the caller's @timeout@ or 'bounded', which also
-- keeps the waiting thread reachable so the runtime does not end it as deadlocked.
holdUntilTimedOut ∷ IO ()
holdUntilTimedOut = newEmptyMVar >>= \hold → readMVar hold `finally` void (tryPutMVar hold ())

-- | End the scope the way the ending says, running the scope on the parked worker. The outcome of every ending is asserted as
-- it is raised, so an example never passes because the wrong thing happened.
runEnding ∷ Scope → (Probe → IO ()) → Probe → Ending → IO ()
runEnding scope worker probe = \case
  Raises → do
    outcome ← try @Boom (scope (worker probe) (\_ → readMVar (probeParked probe) >> throwIO Boom))
    outcome `shouldBe` Left Boom
  CancelledParked → do
    outcome ←
      try @AsyncException . bounded $
        withCancellationAfter (readMVar (probeParked probe)) (pure ()) (scope (worker probe) (\_ → holdUntilTimedOut))
    outcome `shouldBe` Left UserInterrupt

-- | The judgement the helpers make true: the worker's thread has ended, and been joined, when the scope returns. A thread that
-- is blocked has not ended; one that ended is finished, or is running its last steps after announcing its end, which the poll
-- yields to (a count of yields, never a duration, so a thread that never ends gives up the same way on any machine).
endedAfterScope ∷ Probe → IO Bool
endedAfterScope probe = tryReadMVar (probeThread probe) >>= maybe (pure False) joined

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

-- | The previous, unowned start, the negative controls' only one: it starts the thread, announces its end however it ended, and
-- registers no stop-and-join of its own. The thread is recorded in the caller's rescue list in the same masked step that starts
-- it, so the control can always stop and join it afterwards, even one it kills before it ran anything. The defect the
-- controls model is the missing stop-and-join of the scope, not an unannounced end.
startUnowned ∷ IORef [Unowned] → IO () → IO () → IO ThreadId
startUnowned started letGo action = mask_ $ do
  done ← newEmptyMVar
  thread ← forkIOWithUnmask $ \unmask → unmask action `finally` putMVar done ()
  atomicModifyIORef' started (\known → (Unowned thread done letGo : known, ()))
  pure thread

-- | The unowned start as a 'Scope': start the thread, run the body, and stop nothing.
unownedScope ∷ IORef [Unowned] → Scope
unownedScope started action body = startUnowned started (pure ()) action >>= body

-- | Stop and join every thread an unowned control started, even if an assertion before it failed: let go what it is held at
-- first, then kill it, then wait for its announced end.
reapUnowned ∷ IORef [Unowned] → IO ()
reapUnowned started = do
  known ← readIORef started
  forM_ known $ \(Unowned thread done letGo) → letGo >> killThread thread >> readMVar done

-- | Run a negative control inside its rescue lifetime: the rescue list is made, and the rescue registered, before the control can
-- expose any thread, and it stops and joins whatever the control started on every way out (a normal return, a failed
-- assertion, a timeout of the example, a cancellation), uninterruptibly. The control's own failure stays the one that is
-- raised.
withRescue ∷ (IORef [Unowned] → IO a) → IO a
withRescue control = do
  started ← newIORef []
  control started `finally` uninterruptibleMask_ (reapUnowned started)
