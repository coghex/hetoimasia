{-# LANGUAGE OverloadedStrings #-}

-- | The threads the suite's helpers start are owned (#599): however the scope that needed a thread ends, the thread has ended
-- and been joined before the scope returns.
--
-- Each shape the converted sites fall into has an example that ends the scope while the thread is parked, by a failing body and
-- by a cancellation, and judges that the thread has ended and been joined, and a negative control that applies the same
-- judgement to the start the site made before it was converted and must fail:
--
-- * the scenario runners ('runScenarioAfter'): the scenario's thread, when the session's run is cancelled before the scenario
--   started, and when the example is cancelled once the session has ended and the scenario is still running. The previous
--   runner ('previousRunScenario') is the one the suite had, and is cut at the two places it left the thread: between its start
--   and the cleanup it registered, and after the session's run, where it registered none. The seams that place the cancellation
--   exist in the runner test-side only ('RunnerSeams'); no example passes anything else.
-- * a canceller that waits for a point the session reaches ('Test.LuaEngine.Session.Construction'), including when the example
--   fails before the point is reached;
-- * a writer parked in a held sink ('Test.LuaEngine.Facade.Sinks'): the stop lets the sink go, so the join completes;
-- * a supplier whose exit is still running: it is not ended before the exit.
--
-- State owner: each example owns the cells it passes its helper and its 'Cleanups'. Thread: the helper's. Lifetime: the example's.
-- Disposal: the facility's release, or, for a control, 'runCleanups' after the judgement has been recorded. Nothing here sleeps:
-- every wait is an @MVar@, a gate or the runtime's report of a thread, and a bound exists only to keep a stuck example from
-- hanging the run.
module Test.LuaEngine.Owned (spec) where

import Control.Concurrent (ThreadId, forkIO, killThread, myThreadId, throwTo)
import Control.Concurrent.MVar (MVar, isEmptyMVar, newEmptyMVar, putMVar, readMVar, takeMVar, tryPutMVar)
import Control.Exception (AsyncException (ThreadKilled, UserInterrupt), ErrorCall (ErrorCall), SomeException, finally, mask, onException, throwIO, try)
import Control.Monad (void)
import Data.Foldable (for_)
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import System.IO (hPutStrLn, stderr)
import Test.Hspec
import Test.LuaEngine.Session.Support
import Test.LuaEngine.Unowned
import Test.Support.Bounded (bounded)
import Test.Support.Owned (withOwnedThread)

-- The runners -------------------------------------------------------------------------------------------------------------

-- | The runner the suite had before #599: the scenario's thread started under mask, and its end waited for on the paths below,
-- by a cleanup registered with 'onException' after the start returned. It is the previous unowned start the negative controls
-- judge: it leaves the thread when the example is cancelled between its start and that cleanup, and when it is cancelled once
-- the session has ended. It differs from 'runScenarioSeamed' in nothing else.
previousRunScenario ∷ RunnerSeams → SessionEnv → Harness → (Session → IO ()) → IO SessionOutcome
previousRunScenario seams env harness scenario = do
  handleVar ← newEmptyMVar
  resultVar ← newEmptyMVar
  terminated ← newEmptyMVar
  thread ← mask $ \restore →
    forkIO $
      ( do
          session ← readMVar handleVar
          result ← try (restore (scenario session))
          case result of
            Left (failure ∷ SomeException) → do
              hPutStrLn stderr ("scenario failed with " <> show failure)
              requestStop session StopQuit
              putMVar resultVar (Left failure)
            Right () → putMVar resultVar (Right ())
          letScenarioGo env
      )
        `finally` putMVar terminated ()
  -- the gap: the thread exists, and the cleanup below is not registered yet
  seamStarted seams thread
  outcome ← runSession (scenarioSpec env harness) (putMVar handleVar) `onException` (killThread thread >> takeMVar terminated)
  seamEnded seams
  finished ← try (bounded (readMVar resultVar))
  case finished of
    Left (ErrorCall why) → do
      killThread thread
      takeMVar terminated
      throwIO (ErrorCall ("the scenario did not finish after the session ended: " <> why))
    Right result → do
      takeMVar terminated
      either throwIO (const (pure outcome)) result

-- | A runner over seams: the one the suite uses, and the previous one.
type Runner = RunnerSeams → SessionEnv → Harness → (Session → IO ()) → IO SessionOutcome

-- | Record every thread the runner starts, and place a cancellation of the example where the seams say.
recording ∷ IORef [ThreadId] → IO () → RunnerSeams
recording seen ended = RunnerSeams {seamStarted = \thread → atomicModifyIORef' seen (\held → (thread : held, ())), seamEnded = ended}

-- | End and join what a control left, newest first, each even if an earlier one failed.
stopNoted ∷ IORef [ThreadId] → IO ()
stopNoted seen = do
  threads ← readIORef seen
  for_ threads $ \thread → killThread thread `finally` void (hasEnded thread)

-- | The session's run is cancelled before the scenario started: the scenario's thread exists, is parked waiting for the
-- session's handle, and the cancellation lands where the runner has not yet registered anything of its own. Whether the thread
-- has ended and been joined once the runner raised.
cancelledBeforeScenario ∷ Runner → IORef [ThreadId] → IO Bool
cancelledBeforeScenario runner seen =
  withSetup (setup (roleScript printScript)) $ \env → do
    -- the cancellation is delivered by the seam that learns the thread: nothing has run of the session yet
    let known = recording seen (pure ())
        seams = known {seamStarted = \thread → seamStarted known thread >> throwIO UserInterrupt}
    outcome ← try @AsyncException (bounded (runner seams env (sxHarness (seSpec env)) (\_ → pure ())))
    either (`shouldBe` UserInterrupt) (const (expectationFailure "the cancellation was lost")) outcome
    allJoined seen

-- | The example is cancelled once the session has ended and the scenario is still running (it requested the stop, saw the
-- retirement and parks): the runner has nothing left but to wait for the scenario. Whether the thread has ended and been joined
-- once the runner raised.
cancelledOnceTheSessionEnded ∷ Runner → IORef [ThreadId] → MVar () → IO Bool
cancelledOnceTheSessionEnded runner seen hold =
  withSetup (setup (roleScript printScript)) $ \env → do
    let seams = recording seen (throwIO UserInterrupt)
        scenario session = requestStop session StopQuit >> void (awaitRetired session) >> readMVar hold
    outcome ← try @AsyncException (bounded (runner seams env (sxHarness (seSpec env)) scenario))
    either (`shouldBe` UserInterrupt) (const (expectationFailure "the cancellation was lost")) outcome
    allJoined seen

-- Shapes the scopes take --------------------------------------------------------------------------------------------------

-- | A canceller that waits for a point the session reaches, which the example never lets it reach, in a scope that ends the way
-- the ending says: whether the thread has ended and been joined when the scope returned.
cancellerNeverReached ∷ Ending → Scope → IO Bool
cancellerNeverReached ending scope = do
  seen ← newIORef []
  point ← newEmptyMVar ∷ IO (MVar ())
  started ← newEmptyMVar
  driver ← myThreadId
  runEnding ending $ \end →
    scope (pure ()) (noteThread seen >> putMVar started () >> readMVar point >> throwTo driver ThreadKilled) $ \_ _ →
      end (bounded (readMVar started))
  joined ← allJoined seen
  -- the point stays reachable until the judgement is made, so the runtime does not end the parked thread as deadlocked
  isEmptyMVar point `shouldReturn` True
  pure joined

-- | A writer parked in a held sink of the output the example owns, in a scope that ends the way the ending says. The gate it is
-- held at is not opened by the example: only the scope lets it go, which is the thing judged. A control stops what it left
-- before the output's own scope ends, because that waits for the call inside the sink; the judgement is made first.
parkedWriter ∷ Ending → Scope → IO () → IO Bool
parkedWriter ending scope afterwards = do
  seen ← newIORef []
  entered ← newEmptyMVar
  gate ← newEmptyMVar
  let sink = OutputSink {sinkLine = \_ → putMVar entered () >> takeMVar gate, sinkFlush = pure ()}
      letGo = void (tryPutMVar gate ())
  withOutput sink sink $ \output → do
    runEnding ending $ \end → scope letGo (noteThread seen >> writeAuthored output Stdout ["held"]) $ \_ _ → end (bounded (takeMVar entered))
    joined ← allJoined seen
    afterwards
    pure joined

-- | Whether the supplier is still running when the exit it serves runs. @Enclosing@ is the shape of the converted sites: the
-- supplier's scope encloses the exit, which ends it afterwards. @Preceding@ is the shape they had: the supplier is ended and
-- joined by its own scope, and the exit runs after it.
data Nesting = Enclosing | Preceding

supplierAtExit ∷ Nesting → IO Bool
supplierAtExit nesting = do
  seen ← newIORef []
  started ← newEmptyMVar
  hold ← newEmptyMVar
  running ← newEmptyMVar
  let supplier = noteThread seen >> putMVar started () >> readMVar hold
      exit = do
        threads ← readIORef seen
        ended ← and <$> mapM hasEnded threads
        putMVar running (not ended)
  case nesting of
    Enclosing → withOwnedThread supplier (\_ _ → bounded (readMVar started) `finally` exit)
    Preceding → withOwnedThread supplier (\_ _ → bounded (readMVar started)) `finally` exit
  answer ← readMVar running
  -- the hold stays reachable until the judgement is made, so the runtime does not end the parked thread as deadlocked
  isEmptyMVar hold `shouldReturn` True
  pure answer

spec ∷ Spec
spec = describe "the threads the helpers start are owned (#599)" $ do
  describe "a scenario runner" $ do
    it "has ended and joined the scenario's thread when the session's run is cancelled before the scenario started" $ do
      seen ← newIORef []
      hold ← newEmptyMVar
      cancelledBeforeScenario runScenarioSeamed seen >>= (`shouldBe` True)
      void (tryPutMVar hold ())
    it "has ended and joined the scenario's thread when the example is cancelled once the session has ended and the scenario is still running" $ do
      seen ← newIORef []
      hold ← newEmptyMVar
      cancelledOnceTheSessionEnded runScenarioSeamed seen hold >>= (`shouldBe` True)
      void (tryPutMVar hold ())
    it "raises what the scenario raised once the session has ended and the scenario's thread has terminated" $
      withSetup (setup (roleScript printScript)) $ \env → do
        seen ← newIORef []
        outcome ← try @ErrorCall (runScenarioSeamed (recording seen (pure ())) env (sxHarness (seSpec env)) (\_ → throwIO (ErrorCall "the scenario failed")))
        either (`shouldBe` ErrorCall "the scenario failed") (const (expectationFailure "the scenario's failure was lost")) outcome
        allJoined seen `shouldReturn` True
    it "negative control: the previous runner leaves the scenario's thread when the cancellation lands between its start and the cleanup it registered" $ do
      seen ← newIORef []
      -- The judgement is recorded first; only then is the thread the control left stopped and joined.
      (cancelledBeforeScenario previousRunScenario seen >>= (`shouldBe` False)) `finally` stopNoted seen
    it "negative control: the previous runner leaves the scenario's thread when the example is cancelled once the session has ended" $ do
      seen ← newIORef []
      hold ← newEmptyMVar
      (cancelledOnceTheSessionEnded previousRunScenario seen hold >>= (`shouldBe` False)) `finally` (void (tryPutMVar hold ()) >> stopNoted seen)
  for_ endings $ \(label, ending) → do
    describe ("a canceller that waits for a point the session reaches, when " <> label) $ do
      it "has ended and been joined when its scope returns, though the point was never reached" $
        cancellerNeverReached ending ownedScope >>= (`shouldBe` True)
      it "negative control: an unowned canceller is left waiting for the point" $ do
        cleanups ← newCleanups
        (cancellerNeverReached ending (unownedScope cleanups) >>= (`shouldBe` False)) `finally` runCleanups cleanups
    describe ("a writer parked in a held sink, when " <> label) $ do
      it "is let go by the stop, and has ended and been joined when its scope returns" $
        parkedWriter ending ownedScope (pure ()) >>= (`shouldBe` True)
      it "negative control: an unowned writer is left parked in the sink" $ do
        cleanups ← newCleanups
        parkedWriter ending (unownedScope cleanups) (runCleanups cleanups) >>= (`shouldBe` False)
  describe "a supplier whose exit is still running" $ do
    it "is not ended before the exit it serves: its scope encloses the exit" $
      supplierAtExit Enclosing >>= (`shouldBe` True)
    it "negative control: a supplier ended and joined by its own scope is gone when the exit runs" $
      supplierAtExit Preceding >>= (`shouldBe` False)
