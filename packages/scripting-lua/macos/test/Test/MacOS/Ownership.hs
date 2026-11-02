-- | The regression examples for the two threads the probe library owns on its own (#598): an endpoint's backlog thread and a
-- launched helper's output reader. The library may not depend on the test-support facility, so these owners are implemented
-- with @base@ alone and are not covered by the shared examples; they are judged here.
--
-- /The endpoint./ With its thread parked in the accept wait, the scope's release frees the wait and joins the thread before the
-- descriptor is closed, however the scope ends. The seam 'seamBeforeClose' observes the thread at the moment just before the
-- descriptor is let go: it has ended by then.
--
-- /The launched helper./ The reader's teardown completes before the launch's scope returns, on a normal return, a failing body
-- and a cancellation. The helper's @launchedFinished@ flag is not taken as proof of that: the thread's own end is.
--
-- /The controls./ A judgement that cannot fail proves nothing. Each owner has a negative control that applies the same
-- judgement to the previous, unowned shape: a scope that starts a thread and returns without stopping it. The control
-- reproduces that shape inside an owned outer scope, so it adds no start the ownership guard counts: the outer scope owns the
-- thread, the control records its failed judgement first, and the outer scope then stops and joins whatever the control left,
-- even when an assertion fails, so it leaves nothing for a later example.
--
-- Nothing here sleeps: every wait is a gate, an 'MVar' or a yield, and a bound exists only to keep a stuck example from
-- hanging the run.
module Test.MacOS.Ownership (spec) where

import Control.Concurrent (ThreadId, myThreadId, throwTo, yield)
import Control.Concurrent.MVar (MVar, newEmptyMVar, putMVar, readMVar, tryPutMVar)
import Control.Concurrent.STM (readTVarIO)
import Control.Exception (AsyncException (UserInterrupt), Exception, allowInterrupt, finally, mask_, throwIO, try)
import Control.Monad (void)
import Data.IORef (newIORef, readIORef, writeIORef)
import GHC.Conc (BlockReason (BlockedOnException), ThreadStatus (ThreadBlocked, ThreadDied, ThreadFinished), threadStatus)
import System.FilePath ((</>))
import System.IO.Temp (withTempDirectory)
import Test.Hspec

import Hetoimasia.Scripting.Lua.Internal.MacOS.Launch
  ( EndpointSeams (..)
  , Launched (..)
  , awaitReport
  , processGone
  , withEndpointSeamed
  )
import Hetoimasia.Scripting.Lua.Internal.MacOS.Report (Report (..))
import Test.MacOS.Driver (Fixture (..), endQuietly, endWithEscalation, guardMicroseconds, withHelper, withHelperPair)
import Test.Support.Bounded (bounded)
import Test.Support.Cancel (withCancellationAfter)
import Test.Support.Owned (withOwnedThread)

-- | The failure an example raises from a body, told apart from every other.
data Boom = Boom
  deriving (Eq, Show)

instance Exception Boom

-- | Wait where only the example's own end can reach it. The bound or the cancellation ends it.
holdUntilEnded ∷ IO ()
holdUntilEnded = newEmptyMVar >>= \hold → readMVar hold `finally` void (tryPutMVar hold ())

-- | The thread has ended and been joined: finished or died, never blocked. The poll yields through a thread that has announced
-- its end and is leaving (a count of yields, never a duration).
joined ∷ ThreadId → IO Bool
joined thread = go (100000 ∷ Int)
  where
    go 0 = pure False
    go remaining =
      threadStatus thread >>= \case
        ThreadFinished → pure True
        ThreadDied → pure True
        _ → yield >> go (remaining - 1)

-- | Wait until the thread is parked: blocked on something. A thread that ended first is a failure, never a wait.
awaitParked ∷ ThreadId → IO ()
awaitParked thread =
  threadStatus thread >>= \case
    ThreadBlocked _ → pure ()
    ThreadFinished → expectationFailure "the thread ended before it was seen parked"
    ThreadDied → expectationFailure "the thread died before it was seen parked"
    _ → yield >> awaitParked thread

-- | How a scope is made to end while its thread is parked.
data Ending = Returns | Raises | CancelledParked
  deriving (Eq, Show)

-- | End the scope the way the ending says, running the body inside the scope under test. The outcome of every ending is
-- asserted as it is raised.
runEnding ∷ (IO () → IO ()) → Ending → IO ()
runEnding scope = \case
  Returns → scope (pure ())
  Raises → do
    outcome ← try @Boom (scope (throwIO Boom))
    outcome `shouldBe` Left Boom
  CancelledParked → do
    parked ← newEmptyMVar
    outcome ← try @AsyncException . bounded $ withCancellationAfter (readMVar parked) (pure ()) (scope (putMVar parked () >> holdUntilEnded))
    outcome `shouldBe` Left UserInterrupt

endings ∷ [(String, Ending)]
endings =
  [ ("a normal return", Returns)
  , ("a failing body", Raises)
  , ("a cancellation while its thread is parked", CancelledParked)
  ]

-- | The previous, unowned shape: a scope that starts a worker and returns without stopping it. The worker is started by an owned
-- outer scope, so it is stopped and joined whatever the judgement finds; the failed judgement is recorded first and asserted
-- after the outer scope has returned.
leakedAfterScope ∷ IO Bool
leakedAfterScope = do
  parked ← newEmptyMVar
  gate ← newEmptyMVar
  recorded ← newIORef Nothing
  withOwnedThread (myThreadId >>= writeIORef recorded . Just >> putMVar parked () >> readMVar (gate ∷ MVar ())) $ \thread _ → do
    readMVar parked
    -- The scope under test returns here, leaving the worker parked.
    joined thread

spec ∷ SpecWith Fixture
spec = describe "the threads the probe library owns itself (#598)" $ do
  describe "an endpoint's backlog thread (withEndpointSeamed)" $ do
    mapM_
      ( \(label, ending) →
          it ("is freed from its accept wait, joined, and only then is the descriptor let go, on " <> label) $ \_ →
            -- a short directory: a Unix-domain socket path is limited to a hundred or so bytes
            withTempDirectory "/tmp" "own" $ \directory → do
              reaperRef ← newIORef Nothing
              atClose ← newIORef Nothing
              let seams =
                    EndpointSeams
                      { seamReaper = \thread → writeIORef reaperRef (Just thread)
                      , seamBeforeClose = readIORef reaperRef >>= maybe (pure ()) (\thread → joined thread >>= writeIORef atClose . Just)
                      }
              runEnding
                ( \body →
                    withEndpointSeamed seams (directory </> "endpoint.sock") $ \_ → do
                      -- the thread is in the accept wait before the scope ends
                      readIORef reaperRef >>= maybe (expectationFailure "no backlog thread was reported") awaitParked
                      body
                )
                ending
              reaper ← readIORef reaperRef
              maybe (expectationFailure "no backlog thread was reported") (\thread → joined thread `shouldReturn` True) reaper
              -- the descriptor was let go only after the thread had ended
              readIORef atClose `shouldReturn` Just True
      )
      endings
    it "is judged a leak when a scope returns without stopping the thread it started (the previous, unowned shape)" $ \_ → do
      verdict ← leakedAfterScope
      verdict `shouldBe` False

  describe "a launched helper's output reader (withLaunch)" $ do
    mapM_
      ( \(label, ending) →
          it ("has ended and been joined before the launch's scope returns, on " <> label) $ \fixture → do
            kept ← newIORef Nothing
            let first = fixtureFirst fixture
                second = fixtureSecond fixture
            ( runEnding
                ( \body →
                    withHelper fixture first second "hold" 0 $ \launched → do
                      writeIORef kept (Just launched)
                      -- the helper is running and the reader is parked reading its output
                      running ← awaitReport launched guardMicroseconds isFootprint
                      running `shouldSatisfy` maybe False (const True)
                      awaitParked (launchedReader launched)
                      -- A normal return ends the helper first, as every example does; the other endings leave it running.
                      if ending == Returns then void (endWithEscalation launched) else pure ()
                      body
                )
                ending
              )
              `finally` (readIORef kept >>= maybe (pure ()) endQuietly)
            readIORef kept >>= \case
              Nothing → expectationFailure "no helper was launched"
              Just launched → do
                -- the thread's own end is the proof, not the flag the thread sets as it ends
                joined (launchedReader launched) `shouldReturn` True
                finished ← readTVarIO (launchedFinished launched)
                finished `shouldBe` True
      )
      endings
    it "finishes the stream and joins the reader when the scope is left before the reader has run anything" $ \fixture →
      -- Left at once, so the stop can reach the reader at its first unmasked instruction: the stream's cleanup is installed
      -- before that, so the flag is set and the pipe closed however early the reader is stopped (review round 1 of #598).
      mapM_
        ( \_ → do
            kept ← newIORef Nothing
            withHelper fixture (fixtureFirst fixture) (fixtureSecond fixture) "hold" 0 (writeIORef kept . Just)
            readIORef kept >>= \case
              Nothing → expectationFailure "no helper was launched"
              Just launched → do
                (joined (launchedReader launched) `shouldReturn` True) `finally` endQuietly launched
                readTVarIO (launchedFinished launched) `shouldReturn` True
        )
        [1 .. 5 ∷ Int]
    it "ends and reaps both helpers of a pair when a cancellation is already pending as its body begins" $ \fixture → do
      kept ← newIORef Nothing
      caller ← myThreadId
      -- The example is masked and a cancellation is queued against it, blocked in throwTo: the first point the pair's body
      -- can take it is `allowInterrupt`, which is after the cleanup is installed (review round 2 of #598).
      outcome ←
        try @AsyncException . bounded . mask_ $
          withOwnedThread (throwTo caller UserInterrupt) $ \thrower _ → do
            awaitBlockedThrower thrower
            withHelperPair fixture $ \pair → writeIORef kept (Just pair) >> allowInterrupt
      outcome `shouldBe` Left UserInterrupt
      readIORef kept >>= \case
        Nothing → expectationFailure "the pair's body never began"
        Just (first, second) → do
          mapM_ (\launched → processGone (launchedPid launched) `shouldReturn` True) [first, second]
          mapM_ (\launched → joined (launchedReader launched) `shouldReturn` True) [first, second]
    it "is judged a leak when a scope returns without stopping the thread it started (the previous, unowned shape)" $ \_ → do
      verdict ← leakedAfterScope
      verdict `shouldBe` False
 where
  awaitBlockedThrower thrower =
    threadStatus thrower >>= \case
      ThreadBlocked BlockedOnException → pure ()
      ThreadFinished → expectationFailure "the cancellation was delivered before the body began"
      ThreadDied → expectationFailure "the thrower died"
      _ → yield >> awaitBlockedThrower thrower
  isFootprint = \case
    Footprint _ _ → True
    _ → False
