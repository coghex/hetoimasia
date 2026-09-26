-- | Bounded child processes: the private-session children and the commands a
-- private-session child itself runs, such as a compositor's readiness probe.
--
-- A child runs in a process group of its own, with every byte it writes read
-- concurrently, and is waited for until its deadline. One still running then is
-- sent @SIGTERM@ with its whole group, then @SIGKILL@ after 'terminationGrace'
-- seconds, and is reaped either way, so a hung child and anything it started in
-- its group never outlive the example that launched it. A failure of the waiting
-- itself, an interruption included, kills the group before it propagates.
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
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Concurrent.STM (atomically, check, newTVarIO, orElse, readTVar, registerDelay, retry, writeTVar)
import Control.Exception (SomeException, onException, try)
import Control.Monad (void)
import System.Exit (ExitCode)
import System.IO (hGetContents')
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
    -- ^ It was still running when its deadline, in seconds, passed. It was
    -- terminated with its process group and reaped with this status.
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
  outText ← newEmptyMVar
  errText ← newEmptyMVar
  mapM_
    ( \(piped, into) →
        forkIO $
          maybe (pure "") (fmap (either (\(_ ∷ SomeException) → "") id) . try . hGetContents') piped
            >>= putMVar into
    )
    [(pipedOut, outText), (pipedErr, errText)]
  exited ← newTVarIO Nothing
  _ ← forkIO (waitForProcess handle >>= atomically . writeTVar exited . Just)
  let reaped = readTVar exited >>= maybe retry pure
      reapedWithin seconds = do
        timer ← registerDelay (max 1 (round (seconds * 1000000)))
        atomically ((Just <$> reaped) `orElse` (Nothing <$ (readTVar timer >>= check)))
      killGroup = signalGroup sigKILL pid >> atomically reaped
  end ←
    ( reapedWithin deadline >>= \case
        Just status → pure (ChildExited status)
        Nothing → do
          signalGroup sigTERM pid
          reapedWithin terminationGrace >>= \case
            Just status → pure (ChildExpired deadline status)
            Nothing → ChildExpired deadline <$> killGroup
    )
      `onException` killGroup
  Launched end <$> takeMVar outText <*> takeMVar errText <*> pure pid

-- | Signal a child's process group, which it leads; a group already gone is
-- not an error.
signalGroup ∷ Signal → ProcessID → IO ()
signalGroup signal pid = void (try (signalProcessGroup signal pid) ∷ IO (Either SomeException ()))
