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
import Control.Exception (AsyncException (ThreadKilled, UserInterrupt), ErrorCall (ErrorCall), SomeException, finally, mask, onException, throwIO, try, uninterruptibleMask_)
import Control.Monad (void)
import Data.Foldable (for_)
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import System.IO (hPutStrLn, stderr)
import Test.Hspec
import Test.LuaEngine.Session.Support
import Test.LuaEngine.Unowned
import Test.Support.Bounded (bounded)
import Test.Support.Cancel (withCancellationAfter)
import Test.Support.Owned (withOwnedThread)

-- The runners -------------------------------------------------------------------------------------------------------------

-- | The runner the suite had before #599: the scenario's thread started under mask, and its end waited for on the paths below,
-- by a cleanup registered with 'onException' after the start returned. It is the previous unowned start the negative controls
-- judge: it leaves the thread when the example is cancelled between its start and that cleanup, and when it is cancelled once
-- the session has ended. It differs from 'runScenarioSeamed' in nothing else.
previousRunScenario ∷ IORef [ThreadId] → RunnerSeams → SessionEnv → Harness → (Session → IO ()) → IO SessionOutcome
previousRunScenario seen seams env harness scenario = do
  handleVar ← newEmptyMVar
  resultVar ← newEmptyMVar
  terminated ← newEmptyMVar
  -- the control's own cleanup learns the thread in the step that starts it
  thread ← mask $ \restore →
    ( forkIO $
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
    )
      >>= \started → atomicModifyIORef' seen (\held → (started : held, ())) >> pure started
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
stopNoted seen =
  uninterruptibleMask_ $ do
    threads ← readIORef seen
    for_ threads $ \thread → killThread thread `finally` void (hasEnded thread)

-- | Nothing the helper or control started is alive.
noneAlive ∷ IORef [ThreadId] → IO Bool
noneAlive seen = readIORef seen >>= fmap and . mapM hasEnded

-- | Run the helper or control cancelled at once; whatever it started is not alive once it has returned or raised.
cancelledAtOnce ∷ (IORef [ThreadId] → IO ()) → IO Bool
cancelledAtOnce control = do
  seen ← newIORef []
  void (try @AsyncException (bounded (withCancellationAfter (pure ()) (pure ()) (control seen))))
  noneAlive seen

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
cancellerNeverReached ∷ IORef [ThreadId] → Ending → Scope → IO Bool
cancellerNeverReached seen ending scope = do
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
parkedWriter ∷ IORef [ThreadId] → Ending → Scope → IO () → IO Bool
parkedWriter seen ending scope afterwards = do
  entered ← newEmptyMVar
  gate ← newEmptyMVar
  let sink = OutputSink {sinkLine = \_ → putMVar entered () >> takeMVar gate, sinkFlush = pure ()}
      letGo = void (tryPutMVar gate ())
  withOutput sink sink $ \output →
    -- the control's cleanup is a finalizer around the scenario and its judgement, inside the output's scope and registered before the
    -- writer starts: the output's own exit waits for the call inside the sink, so it must never be reached with the writer parked
    ( do
        runEnding ending $ \end → scope letGo (noteThread seen >> writeAuthored output Stdout ["held"]) $ \_ _ → end (bounded (takeMVar entered))
        allJoined seen
    )
      `finally` afterwards

-- | Whether the supplier is still running when the exit it serves runs. @Enclosing@ is the shape of the converted sites: the
-- supplier's scope encloses the exit, which ends it afterwards. @Preceding@ is the shape they had: the supplier is ended and
-- joined by its own scope, and the exit runs after it.
data Nesting = Enclosing | Preceding

supplierAtExit ∷ IORef [ThreadId] → Nesting → IO Bool
supplierAtExit seen nesting = do
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
      (cancelledBeforeScenario (previousRunScenario seen) seen >>= (`shouldBe` False)) `finally` stopNoted seen
    it "negative control: the previous runner leaves the scenario's thread when the example is cancelled once the session has ended" $ do
      seen ← newIORef []
      hold ← newEmptyMVar
      (cancelledOnceTheSessionEnded (previousRunScenario seen) seen hold >>= (`shouldBe` False)) `finally` (void (tryPutMVar hold ()) >> stopNoted seen)
  for_ endings $ \(label, ending) → do
    describe ("a canceller that waits for a point the session reaches, when " <> label) $ do
      it "has ended and been joined when its scope returns, though the point was never reached" $ do
        seen ← newIORef []
        cancellerNeverReached seen ending ownedScope >>= (`shouldBe` True)
      it "negative control: an unowned canceller is left waiting for the point" $ do
        cleanups ← newCleanups
        seen ← newIORef []
        (cancellerNeverReached seen ending (unownedScope cleanups) >>= (`shouldBe` False)) `finally` runCleanups cleanups
    describe ("a writer parked in a held sink, when " <> label) $ do
      it "is let go by the stop, and has ended and been joined when its scope returns" $ do
        seen ← newIORef []
        parkedWriter seen ending ownedScope (pure ()) >>= (`shouldBe` True)
      it "negative control: an unowned writer is left parked in the sink" $ do
        cleanups ← newCleanups
        seen ← newIORef []
        parkedWriter seen ending (unownedScope cleanups) (runCleanups cleanups) >>= (`shouldBe` False)
  describe "a supplier whose exit is still running" $ do
    it "is not ended before the exit it serves: its scope encloses the exit" $ do
      seen ← newIORef []
      supplierAtExit seen Enclosing >>= (`shouldBe` True)
    it "negative control: a supplier ended and joined by its own scope is gone when the exit runs" $ do
      seen ← newIORef []
      supplierAtExit seen Preceding >>= (`shouldBe` False)
    it "leaves nothing alive when it is cancelled at once" $
      cancelledAtOnce (\seen → void (supplierAtExit seen Enclosing)) >>= (`shouldBe` True)
  describe "cancelled at once" $ do
    it "a scenario runner leaves nothing alive" $ do
      hold ← newEmptyMVar
      joined ← cancelledAtOnce (\seen → void (cancelledOnceTheSessionEnded runScenarioSeamed seen hold))
      void (tryPutMVar hold ())
      joined `shouldBe` True
    it "the previous runner's control leaves nothing alive" $ do
      hold ← newEmptyMVar
      joined ← cancelledAtOnce (\seen → void (cancelledOnceTheSessionEnded (previousRunScenario seen) seen hold) `finally` (void (tryPutMVar hold ()) >> stopNoted seen))
      joined `shouldBe` True
    for_ endings $ \(label, ending) → do
      it ("a canceller and its control leave nothing alive, when " <> label) $ do
        cleanups ← newCleanups
        joined ← cancelledAtOnce (\seen → void (cancellerNeverReached seen ending (unownedScope cleanups)) `finally` runCleanups cleanups)
        joined `shouldBe` True
      it ("a writer parked in a held sink and its control leave nothing alive, when " <> label) $ do
        cleanups ← newCleanups
        joined ← cancelledAtOnce (\seen → void (parkedWriter seen ending (unownedScope cleanups) (runCleanups cleanups)))
        joined `shouldBe` True
