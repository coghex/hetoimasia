-- | The regression examples for the threads this suite's own helpers start (#598): the example bound, the helper beside an
-- example, a thrower that cancels a thread held in the timer's arming, and the producers the stress examples start.
--
-- /The judgement./ A helper owns its threads when, however the scope that needed them ends (a thing that returned, a failing
-- body, a bound that expired, a cancellation), every thread it started has ended and been joined by the time the scope
-- returns. 'endedAfter' makes that judgement about the threads the scope reported (through a test-side seam) or recorded
-- itself, so a thread killed before it ran anything is still judged.
--
-- /The controls./ A judgement that cannot fail proves nothing. Each shape has a negative control that applies the same
-- judgement to the previous, unowned shape: a scope that starts a thread and returns without stopping it. The control
-- reproduces that shape inside an owned outer scope, so it adds no start the ownership guard counts: the outer scope owns the
-- thread, the control records its failed judgement first, and the outer scope then stops and joins whatever the control left,
-- even when an assertion fails, so it leaves nothing for a later example.
--
-- State owner: each example owns its probe. Thread: every thread is owned by a scope. Nothing here sleeps: every wait is a
-- gate, an 'MVar' or a yield, and a bound exists only to keep a stuck example from hanging the run.
module Test.LuaRuntime.Ownership (spec) where

import Control.Concurrent (ThreadId, myThreadId, throwTo, yield)
import Control.Concurrent.MVar (MVar, newEmptyMVar, putMVar, readMVar, tryPutMVar)
import Control.Exception (AsyncException (ThreadKilled, UserInterrupt), Exception, SomeException, finally, throwIO, try, uninterruptibleMask_)
import Control.Monad (forM_, void)
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import GHC.Conc (ThreadStatus (ThreadDied, ThreadFinished), threadStatus)
import Test.Hspec (Expectation, Spec, describe, expectationFailure, it, shouldBe, shouldReturn)
import Test.LuaRuntime.Scheduler.Support (awaitDelivered)
import Test.LuaRuntime.Support (Broken (Broken), alongsideOpeningObserving, bounded, boundedAfterObserving, withProducers)
import Test.Support.Cancel (withCancellationAfter)
import Test.Support.Owned (withOwnedThread, withOwnedThreadOpening)

-- | What an example watches: the threads a scope reported or recorded, and the worker's gates.
data Probe = Probe
  { probeThreads ∷ !(IORef [ThreadId])
  -- ^ The threads the example judges, in the order they were reported.
  , probeParked ∷ !(MVar ())
  -- ^ Filled when a worker reached its gate.
  , probeGate ∷ !(MVar ())
  -- ^ The gate a worker waits at; no example opens it, so only a kill, a stop or a cancellation ends the worker.
  }

newProbe ∷ IO Probe
newProbe = Probe <$> newIORef [] <*> newEmptyMVar <*> newEmptyMVar

recordThread ∷ Probe → ThreadId → IO ()
recordThread probe thread = atomicModifyIORef' (probeThreads probe) (\held → (held <> [thread], ()))

-- | A worker: say which thread it is, say it is parked, wait at the gate.
parkedWorker ∷ Probe → IO ()
parkedWorker probe = myThreadId >>= recordThread probe >> putMVar (probeParked probe) () >> readMVar (probeGate probe)

-- | Wait where only the example's own end can reach it. The bound or the cancellation ends it.
holdUntilEnded ∷ IO ()
holdUntilEnded = newEmptyMVar >>= \hold → readMVar hold `finally` void (tryPutMVar hold ())

-- | The failure an example raises from a body, told apart from every other.
data Boom = Boom
  deriving (Eq, Show)

instance Exception Boom

-- The judgement ---------------------------------------------------------------------------------------------------------

-- | Every thread the example judged has ended and been joined: a finished or died thread, never a blocked one. The poll yields
-- through a thread that has announced its end and is leaving (a count of yields, never a duration).
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

-- | The judgement is made about this many threads, so a scope that reported none cannot pass it.
judged ∷ Probe → Int → Expectation
judged probe expected = (length <$> readIORef (probeThreads probe)) `shouldReturn` expected

-- The endings -----------------------------------------------------------------------------------------------------------

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
  withOwnedThread (parkedWorker probe) $ \_ _ → do
    readMVar (probeParked probe)
    -- The scope under test returns here, leaving the worker parked.
    endedAfter probe

-- The examples ----------------------------------------------------------------------------------------------------------

spec ∷ Spec
spec = describe "the threads this suite's own helpers start (#598)" $ do
  describe "the bound of an example (boundedAfter)" $ do
    forM_
      [ ("an example that finished", pure ())
      , ("an example that failed", throwIO (Broken "its own failure"))
      , ("an example whose bound expired", newEmptyMVar >>= readMVar)
      ]
      $ \(label, example) →
        it ("has ended and joined its watchdog and its interrupter when it returns, for " <> label) $ bounded $ do
          probe ← newProbe
          outcome ← try @SomeException (boundedAfterObserving (\watching interrupting → recordThread probe watching >> recordThread probe interrupting) 100000 100000 example)
          case (label, outcome) of
            ("an example that finished", Left failure) → expectationFailure ("a finished example was failed: " <> show failure)
            ("an example whose bound expired", Right ()) → expectationFailure "an example held past its bound was not failed"
            _ → pure ()
          judged probe 2
          endedAfter probe `shouldReturn` True
    it "is judged a leak when a scope returns without stopping the thread it started (the previous, unowned shape)" $ bounded $ do
      probe ← newProbe
      verdict ← leakedAfterScope probe
      verdict `shouldBe` False

  describe "a helper beside the example (alongsideOpening)" $ do
    forM_ endings $ \(label, ending) → do
      it ("is ended and joined when the example ends with " <> label) $ bounded $ do
        probe ← newProbe
        runEnding
          (alongsideOpeningObserving (recordThread probe) [] (parkedWorker probe))
          (readMVar (probeParked probe))
          ending
        -- the seam reported the helper, and the helper recorded itself: two entries, one thread
        endedAfter probe `shouldReturn` True
        judged probe 2
    it "opens the gates and fails the example with its own failure when the helper fails, and has ended by then" $ bounded $ do
      probe ← newProbe
      opened ← newEmptyMVar
      outcome ←
        try @Boom $
          alongsideOpeningObserving
            (recordThread probe)
            [void (tryPutMVar opened ())]
            (throwIO Boom)
            -- only the helper's failure, through the gate it opens, lets this return
            (readMVar opened >> holdUntilEnded)
      outcome `shouldBe` Left Boom
      judged probe 1
      endedAfter probe `shouldReturn` True
    it "is judged a leak when a scope returns without stopping the helper it started (the previous, unowned shape)" $ bounded $ do
      probe ← newProbe
      verdict ← leakedAfterScope probe
      verdict `shouldBe` False

  describe "a thrower that cancels a thread held where only the example lets it go" $ do
    let scope probe body = do
          entered ← newEmptyMVar
          gate ← newEmptyMVar
          withOwnedThreadOpening
            (void (tryPutMVar gate ()))
            (myThreadId >>= recordThread probe >> uninterruptibleMask_ (putMVar entered () >> readMVar gate))
            $ \held _ → do
              readMVar entered
              withOwnedThread (throwTo held ThreadKilled) $ \thrower _ → do
                recordThread probe thrower
                awaitDelivered thrower
                body
    forM_ endings $ \(label, ending) →
      it ("ends and joins the held thread and its thrower on " <> label) $ bounded $ do
        probe ← newProbe
        thrown ← newEmptyMVar
        runEnding
          (\body → scope probe (putMVar thrown () >> body))
          (readMVar thrown)
          ending
        judged probe 2
        endedAfter probe `shouldReturn` True
    it "ends and joins the held thread when the example fails before the hold was entered" $ bounded $ do
      probe ← newProbe
      entered ← newEmptyMVar
      gate ← newEmptyMVar
      outcome ←
        try @Boom $
          withOwnedThreadOpening
            (void (tryPutMVar gate ()))
            (myThreadId >>= recordThread probe >> uninterruptibleMask_ (putMVar entered () >> readMVar gate))
            (\_ _ → throwIO Boom ∷ IO ())
      outcome `shouldBe` Left Boom
      judged probe 1
      endedAfter probe `shouldReturn` True

    it "is judged a leak when a scope returns without stopping the held thread or its thrower it started (the previous, unowned shape)" $ bounded $ do
      probe ← newProbe
      verdict ← leakedAfterScope probe
      verdict `shouldBe` False

  describe "the producers of a stress example (withProducers)" $ do
    it "is judged a leak when a scope returns without stopping the threads it started (the previous, unowned shape)" $ bounded $ do
      probe ← newProbe
      verdict ← leakedAfterScope probe
      verdict `shouldBe` False
    forM_ endings $ \(label, ending) →
      it ("end and join every thread on " <> label) $ bounded $ do
        probe ← newProbe
        parkedAll ← newEmptyMVar
        runEnding
          ( \body →
              withProducers (replicate 3 (parkedWorker' probe parkedAll)) $ \_ → body
          )
          (readMVar parkedAll)
          ending
        judged probe 3
        endedAfter probe `shouldReturn` True
  where
    -- A worker that also says when every one of the three has parked.
    parkedWorker' probe parkedAll = do
      myThreadId >>= recordThread probe
      count ← length <$> readIORef (probeThreads probe)
      if count == 3 then void (tryPutMVar parkedAll ()) else pure ()
      readMVar (probeGate probe)
