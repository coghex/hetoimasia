-- | Bounded child processes: the private-roots children and the commands a
-- private-roots child itself runs, such as a compositor's readiness probe.
--
-- The GLFW native suite's @Test.GLFW.Native.Child@ is the precedent this
-- follows; AGENTS.md forbids importing a helper from another component's
-- spec, so the Vulkan native suite keeps its own copy.
--
-- A child runs in a process group of its own, with every byte it writes read
-- concurrently, and its deadline covers both its exit and the end of its
-- output: a child that exits while a descendant still holds its output open is
-- not finished. One unfinished at the deadline is sent @SIGTERM@ with its whole
-- group, then @SIGKILL@ after 'terminationGrace' seconds, and is reaped either
-- way; output still held open from outside the group after that is given up on,
-- keeping what was read. Once the child is done, its group is sent @SIGKILL@,
-- so nothing it left running there keeps running, but only the child itself is
-- waited for. A descendant is reaped by its own parent, which for one the child
-- orphaned is whatever adopts orphans — init, a container's init, or launchd —
-- so it may still be a zombie, ended but listed, when this returns. A failure
-- of the waiting itself, an interruption included, kills the group before it
-- propagates.
--
-- __Reclamation.__ A launch owns a process group, two parent-side pipe handles
-- and two output-reader threads, and owns none of them once it returns or
-- propagates, by any path: a normal exit, an expiry, output given up on, a
-- failure while acquiring, or an interruption at any point from acquisition to
-- the result. The readers are stopped, not waited for: an output pipe held open
-- from outside the group is never waited on for end of file, so reclaiming it
-- adds no wait for the escaped writer, which is not ended here and may keep
-- running; what the readers had read is kept. Each reader is stopped by an
-- asynchronous exception and awaited, which is bounded because it is delivered
-- where the reader blocks, and each handle is then closed. Ownership is
-- established under @mask@ in the step that acquires, so there is no
-- interruptible gap between acquiring a pipe or a thread and being responsible
-- for it, and reclamation runs under @uninterruptibleMask_@. A failure to
-- reclaim never replaces the failure that caused it: the primary exception
-- propagates unchanged when reclamation succeeded, and otherwise inside a
-- 'LauncherCleanupFailed' that carries it beside every cleanup failure; a launch
-- that returned normally but could not reclaim raises one with no primary.
--
-- The deadline is enforced from outside the child and reported as
-- 'ChildExpired'. Nothing here decides what an expiry means; a caller that
-- treats a child's output as a verdict decides expiry first.
module Test.GPU.Vulkan.Native.Child
  ( ChildEnd (..)
  , Launched (..)
  , LauncherCleanupFailed (..)
  , Owned (..)
  , terminationGrace
  , launchCommand
  , launchCommandIn
  , launchCommandObserved
  ) where

import Control.Concurrent (ThreadId, forkIO, forkIOWithUnmask, killThread)
import Control.Concurrent.STM (STM, TVar, atomically, check, modifyTVar', newTVarIO, orElse, readTVar, readTVarIO, registerDelay, retry, writeTVar)
import Control.Exception (Exception, SomeException, catch, finally, mask, throwIO, toException, try, uninterruptibleMask_)
import Control.Monad (forM, unless, void)
import qualified Data.ByteString as ByteString
import Data.IORef (IORef, modifyIORef', newIORef, readIORef, writeIORef)
import Data.Maybe (catMaybes)
import qualified Data.Text as Text
import Data.Text.Encoding (decodeUtf8Lenient)
import System.Exit (ExitCode)
import System.IO (Handle, hClose)
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

-- | A failure to reclaim what a launch owned: the exception that ended the
-- launch, if one did, and every failure of the reclamation itself.
data LauncherCleanupFailed = LauncherCleanupFailed !(Maybe SomeException) ![SomeException]
  deriving (Show)

instance Exception LauncherCleanupFailed

-- | What a launch owns while it runs, shown to an observer the moment it is
-- acquired, so a regression can check afterwards that none of it is still held.
data Owned = Owned
  { ownedPid ∷ !ProcessID
  , ownedHandles ∷ ![Handle]
    -- ^ The parent's ends of the child's output pipes: standard output, then
    -- standard error.
  , ownedReadersFinished ∷ ![STM Bool]
    -- ^ Whether each output reader, in the same order, has finished.
  , ownedCaptured ∷ STM (String, String)
    -- ^ What the readers have captured so far, standard output then standard
    -- error, so an observer can wait for a fixture's output rather than a time.
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
launchCommandIn = launchCommandObserved (const (pure ())) terminationGrace

-- | 'launchCommandIn' with the grace after which output held open is given up
-- on, and an observer shown what the launch owns once it owns it. The observer
-- runs where the launch can still be interrupted, with reclamation already
-- arranged, and may not block on the child.
launchCommandObserved ∷ (Owned → IO ()) → Double → Maybe [(String, String)] → Double → FilePath → [String] → IO Launched
launchCommandObserved observe grace environment deadline command arguments = mask $ \restore → do
  (_, pipedOut, pipedErr, handle) ←
    createProcess
      (proc command arguments)
        { env = environment
        , std_in = NoStream
        , std_out = CreatePipe
        , std_err = CreatePipe
        , create_group = True
        }
  -- From here the launch owns the process group, the pipes and, as they start,
  -- the readers; nothing below can be interrupted until 'restore' is applied,
  -- and the handler that reclaims is installed in the same masked step.
  let handles = catMaybes [pipedOut, pipedErr]
  exited ← newTVarIO Nothing
  _ ← forkIO (waitForProcess handle >>= atomically . writeTVar exited . Just)
  readers ← newIORef []
  pidRef ← newIORef Nothing
  let reaped = readTVar exited >>= maybe retry pure
      killGroup = readIORef pidRef >>= mapM_ (signalGroup sigKILL) >> atomically reaped
  outBytes ← newTVarIO ByteString.empty
  errBytes ← newTVarIO ByteString.empty
  outcome ←
    try
      ( do
          pid ← getPid handle >>= maybe (ioError (userError ("the child " <> command <> " exited before its identifier was read"))) pure
          writeIORef pidRef (Just pid)
          finishedFlags ← forM [(pipedOut, outBytes), (pipedErr, errBytes)] $ \(piped, into) → do
            done ← newTVarIO False
            thread ←
              forkIOWithUnmask $ \unmask →
                (mapM_ (drainInto unmask into) piped `catch` \(_ ∷ SomeException) → pure ())
                  `finally` atomically (writeTVar done True)
            modifyIORef' readers ((thread, readTVar done) :)
            pure (readTVar done)
          let finishedOutput = and <$> sequence finishedFlags
              -- Finished means reaped with both pipes at end of file: a descendant
              -- that still holds the child's output keeps it unfinished.
              finished = reaped <* (finishedOutput >>= check)
              within seconds done = do
                timer ← registerDelay (max 1 (round (seconds * 1000000)))
                atomically ((Just <$> done) `orElse` (Nothing <$ (readTVar timer >>= check)))
          end ←
            restore $ do
              observe (Owned pid handles finishedFlags ((,) <$> decodedIn outBytes <*> decodedIn errBytes))
              within deadline finished >>= \case
                Just status → pure (ChildExited status)
                Nothing → do
                  signalGroup sigTERM pid
                  within grace finished >>= \case
                    Just status → pure (ChildExpired deadline status)
                    Nothing → do
                      signalGroup sigKILL pid
                      -- Bounded too: output held open from outside the group is given
                      -- up on, and what was read so far is kept.
                      _ ← within grace finished
                      ChildExpired deadline <$> atomically reaped
          -- Anything the child started in its group and left running is killed with
          -- it. That is not waited for: the child is the only process reaped here.
          signalGroup sigKILL pid
          pure (end, pid)
      )
  case outcome of
    Left (primary ∷ SomeException) → do
      -- The group is killed and reaped, then the readers and the handles are
      -- reclaimed, all uninterruptibly; the failure that ended the launch
      -- propagates as it was unless reclaiming failed too.
      uninterruptibleMask_ $ do
        _ ← try killGroup ∷ IO (Either SomeException ExitCode)
        failures ← reclaim readers handles
        throwIO (if null failures then primary else toException (LauncherCleanupFailed (Just primary) failures))
    Right (end, pid) → do
      failures ← uninterruptibleMask_ (reclaim readers handles)
      unless (null failures) (throwIO (LauncherCleanupFailed Nothing failures))
      Launched end <$> decoded outBytes <*> decoded errBytes <*> pure pid
  where
    -- A reader reads under the caller's unmasked state only while it waits for
    -- bytes, and appends what it read masked, so being stopped loses nothing it
    -- had been given.
    drainInto unmask into piped = do
      chunk ← unmask (ByteString.hGetSome piped 4096)
      unless (ByteString.null chunk) $ do
        atomically (modifyTVar' into (<> chunk))
        drainInto unmask into piped
    decoded bytes = decodeText <$> readTVarIO bytes

decodedIn ∷ TVar ByteString.ByteString → STM String
decodedIn bytes = decodeText <$> readTVar bytes

decodeText ∷ ByteString.ByteString → String
decodeText = Text.unpack . decodeUtf8Lenient

-- | Stop every output reader, awaiting each, and close the parent's pipe
-- handles; the failures it met, if any. The readers are stopped by an
-- asynchronous exception where they block, never waited on for end of file.
reclaim ∷ IORefReaders → [Handle] → IO [SomeException]
reclaim readers handles = do
  held ← readIORef readers
  stopped ← forM held $ \(thread, finishedFlag) →
    try (killThread thread >> atomically (finishedFlag >>= check))
  closed ← forM handles (\piped → try (hClose piped))
  pure ([failure | Left failure ← stopped] <> [failure | Left failure ← closed])

type IORefReaders = IORef [(ThreadId, STM Bool)]

-- | Signal a child's process group, which it leads; a group already gone is
-- not an error.
signalGroup ∷ Signal → ProcessID → IO ()
signalGroup signal pid = void (try (signalProcessGroup signal pid) ∷ IO (Either SomeException ()))
