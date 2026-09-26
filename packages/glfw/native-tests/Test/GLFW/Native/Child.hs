-- | Bounded child processes: the private-session children and the commands a
-- private-session child itself runs, such as a compositor's readiness probe.
--
-- A child runs in a process group of its own, with every byte it writes read
-- concurrently, and its deadline covers both its exit and the end of its
-- output: a child that exits while a descendant still holds its output open is
-- not finished. One unfinished at the deadline is sent @SIGTERM@ with its whole
-- group, then @SIGKILL@ after 'terminationGrace' seconds, and is reaped either
-- way; output still held open from outside the group after that is given up on,
-- keeping what was read. Whatever the child left running in its group is
-- killed once it is done, so neither a hung child nor anything it started
-- outlives the example that launched it. A failure of the waiting itself, an
-- interruption included, kills the group before it propagates.
--
-- The deadline is enforced from outside the child and reported as
-- 'ChildExpired'. Nothing here decides what an expiry means; a caller that
-- treats a child's output as a verdict decides expiry first.
module Test.GLFW.Native.Child
  ( ChildEnd (..)
  , Launched (..)
  , terminationGrace
  , launchCommand
  , launchCommandIn
  ) where

import Control.Concurrent (forkIO)
import Control.Concurrent.STM (atomically, check, newTVarIO, orElse, readTVar, registerDelay, retry, writeTVar)
import Control.Exception (SomeException, catch, finally, onException, try)
import Control.Monad (forM_, unless, void)
import qualified Data.ByteString as ByteString
import Data.IORef (atomicModifyIORef', newIORef, readIORef)
import qualified Data.Text as Text
import Data.Text.Encoding (decodeUtf8Lenient)
import System.Exit (ExitCode)
import System.Posix.Signals (Signal, sigKILL, sigTERM, signalProcessGroup)
import System.Posix.Types (ProcessID)
import System.Process
  ( CreateProcess (create_group, env, std_err, std_in, std_out)
  , StdStream (CreatePipe, NoStream)
  , createProcess
  , getPid
  , proc
  , waitForProcess
  )

-- | How a bounded child ended.
data ChildEnd
  = ChildExited !ExitCode
    -- ^ It exited by itself within its deadline.
  | ChildExpired !Double !ExitCode
    -- ^ It had not finished when its deadline, in seconds, passed: it was still
    -- running, or a descendant still held its output open. Its process group
    -- was terminated, and it was reaped with this status.
  deriving (Eq, Show)

-- | What a bounded child left: how it ended, everything it wrote, and the
-- process identifier it ran as, which is no longer its once this is returned.
data Launched = Launched
  { launchedEnd ∷ !ChildEnd
  , launchedOut ∷ !String
  , launchedErr ∷ !String
  , launchedPid ∷ !ProcessID
  }

-- | How long a child terminated at its deadline has to exit before its process
-- group is killed.
terminationGrace ∷ Double
terminationGrace = 5

-- | Run a command as a bounded child in this process's environment.
launchCommand ∷ Double → FilePath → [String] → IO Launched
launchCommand = launchCommandIn Nothing

-- | Run a command as a bounded child, in the given environment if one is given.
launchCommandIn ∷ Maybe [(String, String)] → Double → FilePath → [String] → IO Launched
launchCommandIn environment deadline command arguments = do
  (_, pipedOut, pipedErr, handle) ←
    createProcess
      (proc command arguments)
        { env = environment
        , std_in = NoStream
        , std_out = CreatePipe
        , std_err = CreatePipe
        , create_group = True
        }
  pid ← getPid handle >>= maybe (ioError (userError ("the child " <> command <> " exited before its identifier was read"))) pure
  outBytes ← newIORef ByteString.empty
  errBytes ← newIORef ByteString.empty
  outDone ← newTVarIO False
  errDone ← newTVarIO False
  forM_ [(pipedOut, outBytes, outDone), (pipedErr, errBytes, errDone)] $ \(piped, into, done) →
    forkIO $
      (mapM_ (drainInto into) piped `catch` \(_ ∷ SomeException) → pure ())
        `finally` atomically (writeTVar done True)
  exited ← newTVarIO Nothing
  _ ← forkIO (waitForProcess handle >>= atomically . writeTVar exited . Just)
  let reaped = readTVar exited >>= maybe retry pure
      -- Finished means reaped with both pipes at end of file: a descendant
      -- that still holds the child's output keeps it unfinished.
      finished = reaped <* (readTVar outDone >>= check) <* (readTVar errDone >>= check)
      within seconds done = do
        timer ← registerDelay (max 1 (round (seconds * 1000000)))
        atomically ((Just <$> done) `orElse` (Nothing <$ (readTVar timer >>= check)))
      killGroup = signalGroup sigKILL pid >> atomically reaped
  end ←
    ( within deadline finished >>= \case
        Just status → pure (ChildExited status)
        Nothing → do
          signalGroup sigTERM pid
          within terminationGrace finished >>= \case
            Just status → pure (ChildExpired deadline status)
            Nothing → do
              signalGroup sigKILL pid
              -- Bounded too: output held open from outside the group is given
              -- up on, and what was read so far is kept.
              _ ← within terminationGrace finished
              ChildExpired deadline <$> atomically reaped
    )
      `onException` killGroup
  -- Anything the child started in its group and left running goes with it.
  signalGroup sigKILL pid
  Launched end <$> decoded outBytes <*> decoded errBytes <*> pure pid
  where
    drainInto into piped = do
      chunk ← ByteString.hGetSome piped 4096
      unless (ByteString.null chunk) $ do
        atomicModifyIORef' into (\held → (held <> chunk, ()))
        drainInto into piped
    decoded bytes = Text.unpack . decodeUtf8Lenient <$> readIORef bytes

-- | Signal a child's process group, which it leads; a group already gone is
-- not an error.
signalGroup ∷ Signal → ProcessID → IO ()
signalGroup signal pid = void (try (signalProcessGroup signal pid) ∷ IO (Either SomeException ()))
