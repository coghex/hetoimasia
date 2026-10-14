-- | Bounded child processes: the private-session children and the commands a
-- private-session child itself runs, such as a compositor's readiness probe.
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
-- __Reclamation.__ A launch owns a process group, a reaper thread, two output
-- readers and the parent's two pipe handles, and owns none of them once it
-- returns or propagates, by any path: a normal exit, an expiry, output given up
-- on, a failure while acquiring, or an interruption at any point from
-- acquisition to the result. It is one composite scope
-- ("Hetoimasia.Foundation.Resource", docs/resources.md): each part is acquired
-- and its release installed as one protected step, so there is no interruptible
-- gap between acquiring a pipe or a thread and being responsible for it, and the
-- releases run in a declared order under @uninterruptibleMask_@: the group is
-- killed and the child reaped, then the readers are stopped, then the handles
-- are closed. The readers are stopped, not waited for: an output pipe held open
-- from outside the group is never waited on for end of file, so reclaiming it
-- adds no wait for the escaped writer, which is not ended here and may keep
-- running; each reader is stopped by an asynchronous exception where it blocks
-- and awaited, which is bounded because the exception is delivered there, and
-- what the readers had read is kept. The scope's failure table applies
-- unchanged: the launch's own failure propagates with its type, value and
-- attached context, every cleanup failure retained beside it as evidence, and a
-- launch that completed but could not reclaim raises its first cleanup failure.
--
-- The deadline is enforced from outside the child and reported as
-- 'ChildExpired'. Nothing here decides what an expiry means; a caller that
-- treats a child's output as a verdict decides expiry first.
module Test.GLFW.Native.Child
  ( ChildEnd (..)
  , Launched (..)
  , Owned (..)
  , terminationGrace
  , launchCommand
  , launchCommandIn
  , launchCommandObserved
  ) where

import Control.Concurrent (ThreadId, forkIO, forkIOWithUnmask, killThread)
import Control.Concurrent.STM (STM, TVar, atomically, check, modifyTVar', newTVarIO, orElse, readTVar, readTVarIO, registerDelay, retry, writeTVar)
import Control.Exception (SomeException, catch, finally, try)
import Control.Monad (unless, void)
import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import qualified Data.Text as Text
import Data.Text.Encoding (decodeUtf8Lenient)
import Hetoimasia.Foundation.Resource (Assembly, acquirePart, releaseRank, restoredStep, withComposite)
import System.Exit (ExitCode)
import System.IO (Handle, hClose)
import System.Posix.Signals (Signal, sigKILL, sigTERM, signalProcessGroup)
import System.Posix.Types (ProcessID)
import System.Process
  ( CreateProcess (create_group, env, std_err, std_in, std_out)
  , ProcessHandle
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

-- | The child as the launch holds it: its handle and identifier, and the
-- parent's ends of its output pipes.
data Child = Child !ProcessHandle !ProcessID !Handle !Handle

-- | An output reader: its thread, and whether it has finished.
data Reader = Reader !ThreadId !(TVar Bool)

-- | Everything the body of a launch uses, assembled and owned by the scope.
data Running = Running
  { runningPid ∷ !ProcessID
  , runningHandles ∷ ![Handle]
  , runningExited ∷ !(TVar (Maybe ExitCode))
  , runningFinished ∷ ![TVar Bool]
  , runningOut ∷ !(TVar ByteString)
  , runningErr ∷ !(TVar ByteString)
  }

-- | 'launchCommandIn' with the grace after which output held open is given up
-- on, and an observer shown what the launch owns once it owns it. The observer
-- runs where the launch can still be interrupted, with reclamation already
-- arranged, and may not block on the child.
launchCommandObserved ∷ (Owned → IO ()) → Double → Maybe [(String, String)] → Double → FilePath → [String] → IO Launched
launchCommandObserved observe grace environment deadline command arguments = do
  (end, pid, out, err) ← withComposite (assembly environment command arguments) $ \running → do
    let reaped = readTVar (runningExited running) >>= maybe retry pure
        finishedOutput = and <$> traverse readTVar (runningFinished running)
        -- Finished means reaped with both pipes at end of file: a descendant
        -- that still holds the child's output keeps it unfinished.
        finished = reaped <* (finishedOutput >>= check)
        pid = runningPid running
        within seconds done = do
          timer ← registerDelay (max 1 (round (seconds * 1000000)))
          atomically ((Just <$> done) `orElse` (Nothing <$ (readTVar timer >>= check)))
    observe
      Owned
        { ownedPid = pid
        , ownedHandles = runningHandles running
        , ownedReadersFinished = map readTVar (runningFinished running)
        , ownedCaptured = (,) <$> decodedIn (runningOut running) <*> decodedIn (runningErr running)
        }
    end ←
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
    -- What was read, taken before the readers are stopped: the readers append
    -- only what they were given, so nothing is lost by stopping them.
    (,,,) end pid <$> readTVarIO (runningOut running) <*> readTVarIO (runningErr running)
  pure (Launched end (decodeText out) (decodeText err) pid)

-- | The launch's parts, each acquired with its release installed in the same
-- protected step. The child's identifier is read at once, before anything waits
-- on the child, because the waiter that reaps it closes the handle the
-- identifier is read from.
assembly ∷ Maybe [(String, String)] → FilePath → [String] → Assembly Running
assembly environment command arguments = do
  Child handle pid out err ←
    acquirePart "child process group" (releaseRank 0) (start environment command arguments) $ \(Child handle pid _ _) → do
      signalGroup sigKILL pid
      void (waitForProcess handle)
  exited ← restoredStep (newTVarIO Nothing)
  _ ←
    acquirePart
      "child reaper"
      (releaseRank 1)
      (forkIO (waitForProcess handle >>= atomically . writeTVar exited . Just))
      (\_ → atomically (readTVar exited >>= maybe retry (const (pure ()))))
  outBytes ← restoredStep (newTVarIO ByteString.empty)
  errBytes ← restoredStep (newTVarIO ByteString.empty)
  outReader@(Reader _ outDone) ← acquirePart "standard output reader" (releaseRank 2) (startReader outBytes out) stopReader
  errReader@(Reader _ errDone) ← acquirePart "standard error reader" (releaseRank 2) (startReader errBytes err) stopReader
  let _ = (outReader, errReader)
  _ ← acquirePart "standard output pipe" (releaseRank 3) (pure out) hClose
  _ ← acquirePart "standard error pipe" (releaseRank 3) (pure err) hClose
  pure (Running pid [out, err] exited [outDone, errDone] outBytes errBytes)

-- | Start the child in a process group of its own and read its identifier. A
-- failure after the pipes exist closes them: nothing here has been returned for
-- the scope to release.
start ∷ Maybe [(String, String)] → FilePath → [String] → IO Child
start environment command arguments = do
  (_, pipedOut, pipedErr, handle) ←
    createProcess
      (proc command arguments)
        { env = environment
        , std_in = NoStream
        , std_out = CreatePipe
        , std_err = CreatePipe
        , create_group = True
        }
  let closeBoth = mapM_ (\piped → try (hClose piped) ∷ IO (Either SomeException ())) (concatMap (maybe [] pure) [pipedOut, pipedErr])
  case (pipedOut, pipedErr) of
    (Just out, Just err) →
      getPid handle >>= \case
        Just pid → pure (Child handle pid out err)
        Nothing → closeBoth >> ioError (userError ("the child " <> command <> " exited before its identifier was read"))
    _ → closeBoth >> ioError (userError ("the child " <> command <> " was started without its output pipes"))

-- | Start a reader of one pipe into a buffer. It reads under the unmasked state
-- only while it waits for bytes, and appends what it read masked, so being
-- stopped loses nothing it had been given.
startReader ∷ TVar ByteString → Handle → IO Reader
startReader into piped = do
  done ← newTVarIO False
  thread ←
    forkIOWithUnmask $ \unmask →
      (drain unmask `catch` \(_ ∷ SomeException) → pure ())
        `finally` atomically (writeTVar done True)
  pure (Reader thread done)
  where
    drain unmask = do
      chunk ← unmask (ByteString.hGetSome piped 4096)
      unless (ByteString.null chunk) $ do
        atomically (modifyTVar' into (<> chunk))
        drain unmask

-- | Stop a reader where it blocks and await it. It is never waited on for the
-- end of its pipe, which a writer outside the group may hold open for good.
stopReader ∷ Reader → IO ()
stopReader (Reader thread done) = killThread thread >> atomically (readTVar done >>= check)

decodedIn ∷ TVar ByteString → STM String
decodedIn bytes = decodeText <$> readTVar bytes

decodeText ∷ ByteString → String
decodeText = Text.unpack . decodeUtf8Lenient

-- | Signal a child's process group, which it leads; a group already gone is
-- not an error.
signalGroup ∷ Signal → ProcessID → IO ()
signalGroup signal pid = void (try (signalProcessGroup signal pid) ∷ IO (Either SomeException ()))
