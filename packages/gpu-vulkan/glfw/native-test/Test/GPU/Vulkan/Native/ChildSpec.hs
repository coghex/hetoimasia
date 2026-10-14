-- | The bounded child launcher's ownership, proven without a session, a display
-- or consent: once a launch returns or propagates it owns no output reader and
-- no parent-side pipe handle ("Test.GPU.Vulkan.Native.Child").
--
-- Each example asks what the launch still holds afterwards: the observer is shown
-- the parent's pipe handles and each reader's completion the moment they are
-- acquired, and the example reads them once the launch is over. The examples cover
-- a child that exits with its output complete, one that exits while a writer in a
-- session of its own holds both output pipes open (the output read so far kept and
-- the launch expired, with that writer still running when its readers have been
-- reclaimed), and an interruption reaching a launch. A writer left running never
-- supplies the end of file that would let a reader finish on its own, and none of
-- this reads a clock, a thread count or a descriptor count. They run with
-- @HETOIMASIA_NATIVE_SESSION@ unset, like the other approval-free examples, and
-- are selected with @--match "a bounded child launcher"@.
module Test.GPU.Vulkan.Native.ChildSpec (spec) where

import Control.Concurrent (forkIO, newEmptyMVar, putMVar, takeMVar, throwTo)
import Control.Concurrent.STM (atomically, check)
import Control.Exception (ErrorCall (..), IOException, bracket, finally, fromException, try)
import Control.Monad (void)
import Data.IORef (newIORef, readIORef, writeIORef)
import GHC.Clock (getMonotonicTime)
import System.Directory (createDirectoryIfMissing, doesFileExist, getTemporaryDirectory, removeDirectoryRecursive)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO (hIsClosed)
import System.Posix.Process (getProcessID)
import System.Posix.Signals (nullSignal, sigKILL, signalProcess, signalProcessGroup)
import System.Posix.Types (ProcessID)
import Test.Hspec (Spec, describe, expectationFailure, it, shouldBe, shouldReturn, shouldSatisfy)
import System.Timeout (timeout)
import Text.Read (readMaybe)

import qualified Test.GPU.Vulkan.Native.Child as Child

spec ∷ Spec
spec = describe "a bounded child launcher" $ do
  -- The launcher's ownership. Each example below asks what the launch still
  -- holds after it has returned or propagated: the observer is shown the
  -- parent's pipe handles and each reader's completion the moment they are
  -- acquired, and the example reads them afterwards. A writer left running
  -- never supplies the end of file that would let a reader finish on its own,
  -- and none of this reads a clock, a thread count or a descriptor count.
  it "owns no reader or pipe handle after a child that exits with its output complete" $ do
    owned ← newIORef Nothing
    launched ← bounded (Child.launchCommandObserved (writeIORef owned . Just) Child.terminationGrace Nothing 30 "sh" ["-c", "echo out; echo err >&2"])
    Child.launchedEnd launched `shouldBe` Child.ChildExited ExitSuccess
    (Child.launchedOut launched, Child.launchedErr launched) `shouldBe` ("out\n", "err\n")
    readIORef owned >>= maybe (expectationFailure "the launch showed its observer nothing") reclaimed

  it "owns no reader or pipe handle after giving up on output a writer in another session holds open, and keeps what was read" $
    withEscapedWriter $ \pidFile → do
      owned ← newIORef Nothing
      let expected = ("escaped-out\npartial success\n", "escaped-err\npartial err\n")
          -- Waits for the fixture's whole output, so the deadline below starts
          -- only once the direct child has said everything and is exiting.
          observe o = do
            atomically (Child.ownedCaptured o >>= check . (== expected))
            writeIORef owned (Just o)
      launched ← bounded (Child.launchCommandObserved observe 0.05 Nothing 0.05 "python3" ["-c", escapedWriter, pidFile])
      Child.launchedEnd launched `shouldSatisfy` \case Child.ChildExpired _ _ → True; _ → False
      (Child.launchedOut launched, Child.launchedErr launched) `shouldBe` expected
      readIORef owned >>= maybe (expectationFailure "the launch showed its observer nothing") reclaimed
      -- The writer is still running, so nothing above was ended by it ending.
      escaped ← escapedPid pidFile
      try (signalProcess nullSignal escaped) >>= (`shouldSatisfy` either (\(_ ∷ IOException) → False) (const True))

  it "owns no reader or pipe handle when an interruption reaches the launch, and propagates the interruption" $ do
    acquired ← newEmptyMVar
    result ← newEmptyMVar
    launcher ← forkIO (try (Child.launchCommandObserved (putMVar acquired) Child.terminationGrace Nothing 300 "sh" ["-c", "sleep 300"]) >>= putMVar result)
    owned ← takeMVar acquired
    -- Whatever the child does next, it is ended with its group on the way out.
    ( do
        throwTo launcher (ErrorCall "the launch was interrupted")
        outcome ← bounded (takeMVar result)
        case outcome of
          Left failure → fmap (\(ErrorCall message) → message) (fromException failure) `shouldBe` Just "the launch was interrupted"
          Right (_ ∷ Child.Launched) → expectationFailure "the interrupted launch returned"
        reclaimed owned
        try (signalProcess nullSignal (Child.ownedPid owned)) >>= (`shouldSatisfy` either (\(_ ∷ IOException) → True) (const False))
      )
      `finally` void (try (signalProcessGroup sigKILL (Child.ownedPid owned)) ∷ IO (Either IOException ()))


-- | An example's wait, bounded so that a launcher that waits for an output pipe's
-- end of file, which an escaped writer never supplies, fails the example instead
-- of hanging the run. The bound is a failure bound, not a performance threshold.
bounded ∷ IO a → IO a
bounded action = timeout 60000000 action >>= maybe (fail "the launch did not return within a minute") pure

-- | Both parent-side handles closed and both readers finished.
reclaimed ∷ Child.Owned → IO ()
reclaimed owned = do
  mapM hIsClosed (Child.ownedHandles owned) `shouldReturn` [True, True]
  atomically (sequence (Child.ownedReadersFinished owned)) `shouldReturn` [True, True]

-- | A direct child that leaves a descendant in a session of its own holding
-- both inherited output pipes open, and waits for nothing else. The descendant
-- records its identifier, says one line on each stream, and tells the direct
-- child it is ready; the direct child then says one line on each stream and
-- exits. The descendant then blocks on a pipe nothing writes to, ending only when
-- it is killed.
escapedWriter ∷ String
escapedWriter =
  unlines
    [ "import os, sys"
    , "pid_file = sys.argv[1]"
    , "ready_read, ready_write = os.pipe()"
    , "if os.fork() == 0:"
    , "    os.setsid()"
    , "    os.close(ready_read)"
    , "    with open(pid_file + '.tmp', 'w') as f:"
    , "        f.write(str(os.getpid()))"
    , "    os.rename(pid_file + '.tmp', pid_file)"
    , "    sys.stdout.write('escaped-out\\n'); sys.stdout.flush()"
    , "    sys.stderr.write('escaped-err\\n'); sys.stderr.flush()"
    , "    os.write(ready_write, b'x')"
    , "    hold_read, hold_write = os.pipe()"
    , "    os.read(hold_read, 1)"
    , "    os._exit(0)"
    , "os.close(ready_write)"
    , "os.read(ready_read, 1)"
    , "sys.stdout.write('partial success\\n'); sys.stdout.flush()"
    , "sys.stderr.write('partial err\\n'); sys.stderr.flush()"
    , "os._exit(0)"
    ]

-- | A scratch directory for the escaped writer's identifier file, and the writer
-- killed on every way out: its identifier is read from the file once there is
-- one, so a failure at any point, even before the launcher returned, still ends it.
withEscapedWriter ∷ (FilePath → IO a) → IO a
withEscapedWriter body =
  bracket
    ( do
        temporary ← getTemporaryDirectory
        self ← getProcessID
        started ← getMonotonicTime
        let directory = temporary </> ("hetoimasia-launcher-" <> show self <> "-" <> show (round (started * 1000000) ∷ Integer))
        createDirectoryIfMissing True directory
        pure directory
    )
    ( \directory → do
        let pidFile = directory </> "escaped.pid"
        present ← doesFileExist pidFile
        if present then escapedPid pidFile >>= \escaped → void (try (signalProcess sigKILL escaped) ∷ IO (Either IOException ())) else pure ()
        removeDirectoryRecursive directory
    )
    (\directory → body (directory </> "escaped.pid"))

-- | The identifier the escaped writer recorded.
escapedPid ∷ FilePath → IO ProcessID
escapedPid pidFile = do
  text ← readFile pidFile
  maybe (fail ("the escaped writer's identifier file held " <> show text)) pure (readMaybe (takeWhile (/= '\n') text))
