-- | An owned child process of the native suite: one place that creates it, one that reaps it, and the evidence of how it ended.
--
-- = What makes each state hold
--
-- * /Owner/: 'withChildUsing', the only place a child is created or reaped.
-- * /Admission to tracking/: the process, both pipes' readers and their end flags are created in one masked step. A
--   failure after the process exists and before the caller holds the 'Child' is rolled back by the very release the
--   caller's own failure uses ('conclude'), so there is one cleanup and not two.
-- * /Terminal evidence/: the exit code from a bounded 'waitForProcess' and both pipes' end flags, each set by the reader
--   that saw the end (or stopped for any reason); a reader that stopped for a reason other than the end of its stream
--   records it where it happened ('childReaderFailures').
-- * /Cleanup/: on every way out the child is killed if it has not exited, reaped within a bound and its readers waited
--   for within a bound, all of it masked. A cancellation that arrives in those bounded waits is remembered across the
--   whole release and raised after it, so a child is never abandoned half-released; the failure of what was being run
--   is raised as itself, or retained beside the cancellation; a child that cannot be confirmed reaped and drained fails
--   an otherwise passing body.
--
-- 'Bounds' and 'Hooks' exist so the harness examples ("Test.Run.Native.ChildSpec") can reach those windows
-- deterministically with explicit synchronization: they are this test-side helper's seams and the command under test has
-- none.
module Test.Run.Native.Child
  ( Child (..)
  , Bounds (..)
  , defaultBounds
  , Hooks (..)
  , noHooks
  , withChild
  , withChildUsing
  ) where

import Control.Concurrent (forkIOWithUnmask)
import Control.Concurrent.STM (TVar, atomically, check, modifyTVar', newTVarIO, readTVar, writeTVar)
import Control.Exception (ExceptionWithContext, IOException, SomeException, finally, mask, onException, rethrowIO, try, tryWithContext)
import Control.Monad (forM_, unless, void)
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.Maybe (isJust)
import qualified Data.Text as Text
import Hetoimasia.Run.Settle (combine, rememberingInterruption)
import System.IO (Handle, hClose, hGetLine, hPutStrLn, hSetEncoding, stderr, utf8)
import System.IO.Error (isEOFError)
import System.Posix.Signals (sigKILL, signalProcess)
import qualified System.Process as Process
import System.Process
  ( CreateProcess (std_err, std_in, std_out)
  , ProcessHandle
  , StdStream (CreatePipe, NoStream)
  , createProcess
  , getPid
  , getProcessExitCode
  , proc
  , waitForProcess
  )
import System.Timeout (timeout)
import Test.Hspec (expectationFailure)

data Child = Child
  { childProcess ∷ ProcessHandle
  , childErr ∷ TVar [Text.Text]
  , childOutEnded ∷ TVar Bool
  , childErrEnded ∷ TVar Bool
  -- ^ Set by each pipe's reader when it has seen its end, which is when everything the child wrote has been read. True
  -- for a stream whose reader was never started, so a release does not wait for one that does not exist.
  , childReaderFailures ∷ TVar [String]
  -- ^ A reader that stopped for any reason other than the end of its stream, recorded where it happened.
  }

-- | How long the release waits, in microseconds, to reap the child and to drain its pipes.
data Bounds = Bounds
  { boundReap ∷ !Int
  , boundDrain ∷ !Int
  }

defaultBounds ∷ Bounds
defaultBounds = Bounds (10 * 1000000) (10 * 1000000)

-- | The helper's test seams. Production use is 'noHooks'.
data Hooks = Hooks
  { hookSpawned ∷ ProcessHandle → IO ()
  -- ^ Run in the acquisition once the process and its readers exist and before the caller holds the 'Child': what an
  -- example raises from to make the acquisition fail part-way. Masked, as the acquisition is.
  , hookReleasing ∷ IO ()
  -- ^ Run at the start of every attempt of the release's bounded waits, interruptibly: where an example parks the release
  -- to deliver a cancellation into it.
  }

noHooks ∷ Hooks
noHooks = Hooks (\_ → pure ()) (pure ())

-- | 'withChildUsing' with the default bounds and no hooks.
withChild ∷ FilePath → [String] → [(String, String)] → (Child → IO a) → IO a
withChild = withChildUsing defaultBounds noHooks

-- | Start the child, run the body, and on every way out kill it if it has not exited, reap it and wait for its readers,
-- each within a bound. The body's own failure, an assertion included, is raised as it is.
withChildUsing ∷ Bounds → Hooks → FilePath → [String] → [(String, String)] → (Child → IO a) → IO a
withChildUsing bounds hooks executable arguments environment body = mask $ \restore → do
  child ← start bounds hooks executable arguments environment
  outcome ← tryWithContext @SomeException (restore (body child))
  conclude bounds hooks child outcome

-- | Release the child, then raise or answer the outcome with what the release found. Called masked.
--
-- A cancellation remembered by the release is raised after it, with the failure of what was being run retained beside
-- it; otherwise a failure is raised as itself, and a child that could not be confirmed reaped and drained fails an
-- otherwise passing outcome.
conclude ∷ Bounds → Hooks → Child → Either (ExceptionWithContext SomeException) a → IO a
conclude bounds hooks child outcome = do
  (problems, interruption) ← release bounds hooks child
  forM_ problems $ \problem → hPutStrLn stderr ("run-native-tests: the command's cleanup was not confirmed: " <> problem)
  case (interruption, outcome) of
    (Just interrupted, Left failure) → rethrowIO =<< combine interrupted [("the failure of what was being run", failure)]
    (Just interrupted, Right _) → rethrowIO interrupted
    (Nothing, Left failure) → rethrowIO failure
    (Nothing, Right result) → do
      unless (null problems) $ expectationFailure ("the command's cleanup was not confirmed: " <> unwords problems)
      pure result

-- | Create the process and its readers in one masked step. A failure after the process exists is rolled back by the same
-- release the caller's own failure uses, because the caller has no 'Child' yet.
start ∷ Bounds → Hooks → FilePath → [String] → [(String, String)] → IO Child
start bounds hooks executable arguments environment = do
  (_, out, err, process) ← createProcess (proc executable arguments) {Process.env = Just environment, std_in = NoStream, std_out = CreatePipe, std_err = CreatePipe}
  errLines ← newTVarIO []
  outEnded ← newTVarIO True
  errEnded ← newTVarIO True
  failures ← newTVarIO []
  let child = Child process errLines outEnded errEnded failures
  acquired ← tryWithContext @SomeException $ do
    (output, diagnostics) ← case (out, err) of
      (Just output, Just diagnostics) → pure (output, diagnostics)
      _ → fail "the child's pipes were not created"
    outLines ← newTVarIO []
    reader "stdout" output outLines outEnded failures
    reader "stderr" diagnostics errLines errEnded failures
    hookSpawned hooks process
  either (conclude bounds hooks child . Left) (const (pure child)) acquired

-- | Read lines until the stream ends, then mark it ended. The loop runs unmasked; the end is marked however it stopped.
-- Only the end of the stream is silent: any other failure of the read is recorded for the case to assert on.
reader ∷ String → Handle → TVar [Text.Text] → TVar Bool → TVar [String] → IO ()
reader name handle ref ended failures = do
  atomically (writeTVar ended False)
  void (forkIOWithUnmask (\unmask → (hSetEncoding handle utf8 >> unmask loop) `finally` (closeQuietly handle >> atomically (writeTVar ended True))))
    `onException` (closeQuietly handle >> atomically (writeTVar ended True))
  where
    loop = do
      line ← try @IOException (hGetLine handle)
      case line of
        Right text → atomically (modifyTVar' ref (<> [Text.pack text])) >> loop
        Left failure
          | isEOFError failure → pure ()
          | otherwise → atomically (modifyTVar' failures (<> [name <> ": " <> show failure]))

closeQuietly ∷ Handle → IO ()
closeQuietly handle = void (try @IOException (hClose handle))

-- | Kill the child if it has not exited, reap it and wait for both readers, each bounded; answer what could not be
-- confirmed, and the first cancellation that interrupted the waits (they are run again until they complete).
release ∷ Bounds → Hooks → Child → IO ([String], Maybe (ExceptionWithContext SomeException))
release bounds hooks child = do
  exited ← getProcessExitCode (childProcess child)
  case exited of
    Just _ → pure ()
    Nothing → do
      target ← getPid (childProcess child)
      -- The child may leave between the check and the kill; the reap below is the authority, so a failed kill is no verdict.
      forM_ target $ \pid → try @IOException (signalProcess sigKILL pid)
  reaped ← newIORef False
  drained ← newIORef False
  interruption ← rememberingInterruption $ do
    hookReleasing hooks
    reapedNow ← timeout (boundReap bounds) (waitForProcess (childProcess child))
    writeIORef reaped (isJust reapedNow)
    drainedNow ← timeout (boundDrain bounds) (atomically (readTVar (childOutEnded child) >>= check >> readTVar (childErrEnded child) >>= check))
    writeIORef drained (isJust drainedNow)
  wasReaped ← readIORef reaped
  wasDrained ← readIORef drained
  pure (["the child was not reaped within its bound of the kill" | not wasReaped] <> ["the child's pipes did not end within their bound" | not wasDrained], interruption)
