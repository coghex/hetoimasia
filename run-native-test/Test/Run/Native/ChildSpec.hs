-- | The native suite's child helper ("Test.Run.Native.Child") on its own failure paths, with no native session: the
-- children are @/bin/sh@ processes and every window is reached by explicit synchronization (a gate and a parked flag), never
-- a sleep. Each case ends by proving the process it started was reaped, because a helper that leaks a child is the defect
-- these cases exist to catch.
module Test.Run.Native.ChildSpec (spec) where

import Control.Concurrent (forkIO, throwTo)
import Control.Concurrent.MVar (MVar, newEmptyMVar, putMVar, readMVar)
import Control.Concurrent.STM (TMVar, atomically, newEmptyTMVarIO, orElse, putTMVar, readTMVar, tryPutTMVar)
import Control.Exception (AsyncException (UserInterrupt), Exception, ExceptionWithContext (ExceptionWithContext), SomeException, fromException, throwIO, tryWithContext)
import Control.Monad (void)
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.List (isInfixOf)
import Hetoimasia.Foundation.Resource (cleanupFailuresInContext)
import System.Environment (getEnvironment)
import System.Exit (ExitCode (ExitFailure))
import System.Posix.Signals (sigKILL)
import System.Process (ProcessHandle, getProcessExitCode, waitForProcess)
import System.Timeout (timeout)
import Test.Hspec (Spec, describe, expectationFailure, it, shouldSatisfy, shouldThrow)
import Test.Run.Native.Child (Bounds (..), Child (..), Hooks (..), defaultBounds, noHooks, withChildUsing)

-- | The failure of what the example runs, told apart from every other.
data BodyFailed = BodyFailed
  deriving (Eq, Show)

instance Exception BodyFailed

-- | The failure an acquisition is made to raise part-way.
data AcquisitionFailed = AcquisitionFailed
  deriving (Eq, Show)

instance Exception AcquisitionFailed

spec ∷ Spec
spec = describe "the child helper" $ do
  describe "a running child" $ do
    it "is killed and reaped, and the body's own failure is raised as itself" $ do
      seen ← newIORef Nothing
      run defaultBounds noHooks (\child → writeIORef seen (Just (childProcess child)) >> throwIO BodyFailed)
        `shouldThrow` (== BodyFailed)
      reapedAfter seen

    it "is killed and reaped when the body passes" $ do
      seen ← newIORef Nothing
      run defaultBounds noHooks (\child → writeIORef seen (Just (childProcess child)))
      reapedAfter seen

  describe "a child that cannot be confirmed" $ do
    it "fails an otherwise passing body when it was not reaped within its bound" $ do
      seen ← newIORef Nothing
      run defaultBounds {boundReap = 0} noHooks (\child → writeIORef seen (Just (childProcess child)))
        `shouldThrow` mentions "cleanup was not confirmed"
      -- The helper killed it and then gave up at once (a zero bound), so whether the kill has taken effect is the kernel's
      -- schedule, not the helper's: the example reaps it itself, within a bound, and requires it to have died of the kill.
      killedAfter seen

    it "fails an otherwise passing body when its pipes did not end within their bound" $ do
      seen ← newIORef Nothing
      run defaultBounds {boundDrain = 0} noHooks (\child → writeIORef seen (Just (childProcess child)))
        `shouldThrow` mentions "cleanup was not confirmed"
      reapedAfter seen

    it "raises the body's failure, not the unconfirmed cleanup, when the body failed" $ do
      seen ← newIORef Nothing
      run defaultBounds {boundReap = 0, boundDrain = 0} noHooks (\child → writeIORef seen (Just (childProcess child)) >> throwIO BodyFailed)
        `shouldThrow` (== BodyFailed)
      killedAfter seen

  describe "a failure part-way through the acquisition" $ do
    it "kills and reaps the process that already exists and raises the failure" $ do
      seen ← newIORef Nothing
      run defaultBounds noHooks {hookSpawned = \process → writeIORef seen (Just process) >> throwIO AcquisitionFailed} (\_ → pure ())
        `shouldThrow` (== AcquisitionFailed)
      reapedAfter seen

    it "reaps the process even when its release is cancelled, and raises the cancellation after it" $ do
      seen ← newIORef Nothing
      outcome ← parkedRelease (\parked gate → noHooks {hookSpawned = \process → writeIORef seen (Just process) >> throwIO AcquisitionFailed, hookReleasing = park parked gate}) (\_ → pure ())
      outcome `shouldSatisfy` cancellation
      reapedAfter seen

  describe "a cancellation during the release" $ do
    it "is remembered across the whole release, which still reaps the child, and raised after it" $ do
      seen ← newIORef Nothing
      outcome ← parkedRelease (\parked gate → noHooks {hookReleasing = park parked gate}) (\child → writeIORef seen (Just (childProcess child)))
      outcome `shouldSatisfy` cancellation
      reapedAfter seen

    it "is raised with the failure of what was being run retained beside it" $ do
      seen ← newIORef Nothing
      outcome ← parkedRelease (\parked gate → noHooks {hookReleasing = park parked gate}) (\child → writeIORef seen (Just (childProcess child)) >> throwIO BodyFailed)
      outcome `shouldSatisfy` cancellation
      -- The body's failure is not lost: it is retained as cleanup evidence in the raised exception's context.
      case outcome of
        Left (ExceptionWithContext context _) → length (cleanupFailuresInContext context) `shouldSatisfy` (>= 1)
        Right () → expectationFailure "the cancellation was not raised"
      reapedAfter seen

-- | A child that stays until it is killed.
run ∷ Bounds → Hooks → (Child → IO a) → IO a
run bounds hooks body = do
  environment ← getEnvironment
  withChildUsing bounds hooks "/bin/sh" ["-c", "exec sleep 1000"] environment body

-- | Run the helper on a thread of its own, park its release at the hook, deliver a cancellation to it there, let the release
-- go on, and answer how the helper ended. Explicit synchronization throughout, every wait bounded: the hook says it is
-- parked, the example then throws, then opens the gate. A helper that never reaches its release (or never ends) fails the
-- example instead of hanging it.
parkedRelease ∷ (TMVar () → MVar () → Hooks) → (Child → IO ()) → IO (Either (ExceptionWithContext SomeException) ())
parkedRelease hooks body = do
  parked ← newEmptyTMVarIO
  gate ← newEmptyMVar
  finished ← newEmptyTMVarIO
  worker ← forkIO (tryWithContext @SomeException (run defaultBounds (hooks parked gate) body) >>= atomically . putTMVar finished)
  reached ← timeout (30 * 1000000) (atomically ((Left <$> readTMVar parked) `orElse` (Right <$> readTMVar finished)))
  case reached of
    Just (Left ()) → pure ()
    Just (Right _) → expectationFailure "the helper ended without reaching its release"
    Nothing → expectationFailure "the helper did not reach its release within 30 seconds"
  throwTo worker UserInterrupt
  putMVar gate ()
  timeout (30 * 1000000) (atomically (readTMVar finished)) >>= maybe (expectationFailure "the helper did not finish within 30 seconds" >> throwIO BodyFailed) pure

-- | The hook that parks the release: say so once, then wait for the gate.
park ∷ TMVar () → MVar () → IO ()
park parked gate = atomically (void (tryPutTMVar parked ())) >> readMVar gate

cancellation ∷ Either (ExceptionWithContext SomeException) () → Bool
cancellation = either (\(ExceptionWithContext _ failure) → fromException failure == Just UserInterrupt) (const False)

mentions ∷ String → SomeException → Bool
mentions needle failure = needle `isInfixOf` show failure

-- | The process was started, and the helper left it reaped: its exit code is known without waiting for anything. For a case in
-- which the helper was expected to confirm the reap; the cases that bound the wait at zero use 'killedAfter'.
reapedAfter ∷ IORef (Maybe ProcessHandle) → IO ()
reapedAfter seen =
  readIORef seen >>= \case
    Nothing → expectationFailure "the example never saw the process"
    Just process → do
      code ← getProcessExitCode process
      case code of
        Just _ → pure ()
        Nothing → do
          -- A child the helper left running (a leak) is reaped here so it cannot outlive the example, and fails it.
          void (timeout (10 * 1000000) (waitForProcess process))
          expectationFailure "the helper left the child running"

-- | The process was started, and the helper, which was told not to wait for it, had killed it: the example performs the reap
-- itself, bounded, and requires the child to have died of SIGKILL (a leaked child would still be sleeping and the bounded
-- wait would end without a status). Nothing assumes when the kill takes effect.
killedAfter ∷ IORef (Maybe ProcessHandle) → IO ()
killedAfter seen =
  readIORef seen >>= \case
    Nothing → expectationFailure "the example never saw the process"
    Just process →
      timeout (10 * 1000000) (waitForProcess process) >>= \case
        Just (ExitFailure code) | code == negate (fromIntegral sigKILL) → pure ()
        other → expectationFailure ("the helper did not kill the child: reaped as " <> show other)
