{-# LANGUAGE InterruptibleFFI #-}

-- | The one way a test starts a subprocess (#588): owned, so that however the scope that started the child ends, the child has
-- been ended, /reaped with the wait confirmed/, and its readers stopped and joined before the scope returns or raises.
--
-- The library calls the test suites used to make do not meet that. @readCreateProcessWithExitCode@ and @withCreateProcess@ end a
-- child that is still running with SIGTERM, close its pipes and reap it in a detached thread (a child that ignores SIGTERM
-- outlives the example, one that obeys is reaped after the call has returned), and neither has a bound of its own. This module
-- offers the same two shapes with the rule applied.
--
-- = Shapes
--
-- * 'runToCompletion' starts a command with a caller-chosen environment, working directory and standard input and answers its
--   exit status and everything it wrote to standard output and standard error ('Completed'), the observable answer of the
--   one-shot library calls. 'runCaptured' is the same answer as the triple those calls returned.
-- * 'withScopedChild' starts a command and lends it to a body ('Child'): for each standard stream the caller chooses whether it
--   is piped and captured, absent, inherited or a handle the caller opened ('Stream'); the body reads the piped output as it
--   arrives ('nextLine', 'captured'), learns the process identifier, sends a signal, waits within a bound of its own
--   ('waitChild'), asks whether the child has exited without reaping it ('childState', 'awaitUnreapedExit'), so a child can be
--   observed exited and not yet reaped; the reap is then done by the release.
--
-- = Ending, on every exit
--
-- Spawning, creating the pipes, starting the readers and registering the release are one masked step. The body runs with the
-- caller's interruptibility restored. The release runs on a normal return, an exception from the body, the expiry of the
-- call's run bound and a cancellation at any point; it is interruptible only in the sense that a cancellation arriving in it is
-- remembered, the step retried and the cancellation raised after the release completed, with the body's failure retained
-- beside it ('RetainedFailure'). It ends the child as the owner decided on 2026-11-02:
--
-- * each child is started in a process group of its own ('OwnGroup', never a session of its own) and the whole group is ended,
--   so a descendant in the group goes with it. SIGTERM, a grace of 2 s, then SIGKILL, and the reap of the direct child is
--   confirmed through its wait. The end of the group is defined by the group, not by its leader: a leader that exits normally or
--   on SIGTERM does not spare a descendant that ignores SIGTERM. That no process of the group remains is a separate, bounded
--   observation (a null signal to the group; a zombie awaiting its parent or the system's adopter still counts as remaining),
--   and when it is not made the call fails as unconfirmed and says so.
-- * The group is signalled only while its identifier is still reserved: while the leader is unreaped, or while a member is known
--   to remain. When the leader has been reaped and a null signal finds no member, nothing is sent, because the identifier can by
--   then belong to an unrelated group.
-- * Exactly two kinds of child stay in the caller's process group and are signalled by process identifier only, with the same
--   escalation: a child that inherits the terminal for a person at the keyboard, and the nested private compositors, which stay
--   in their owning test process's group so the outer launcher's deadline, which ends that group, still ends them
--   ('CallersGroup'). It is chosen by naming it; a spec that does not state it gets 'OwnGroup'.
-- * A child that cannot be confirmed reaped within the reap bound, or pipes that do not end within the drain bound, fail an
--   otherwise-passing call and say which. A body's own failure is raised as itself.
--
-- = Bounds
--
-- Every call states its own run bound ('RunBound'); there is no default and none can be omitted. A human-paced call says
-- 'Unbounded' explicitly and is still ended on a failing body or a cancellation. The reap wait and the drain wait are one fixed
-- 10 s, the grace 2 s ('defaultBounds'); an example of the facility itself shortens them through 'Bounds', an explicit
-- argument, never mutable state. 'Seams' are the test-side hooks the facility's own examples use to reach windows (a failed
-- acquisition, a parked release, a wait that does not observe the exit); production use is 'noSeams'. Nothing here sleeps to
-- coordinate threads. The one place that polls is the observation that no member of a group remains, because the operating system
-- offers no event for a zombie's adoption: it is a bounded wait for the world, never a coordination of two threads.
--
-- = Ownership
--
-- State owner: 'withScopedChildUsing' creates and releases the pipes, the readers, the child and the process group; the caller
-- owns only a handle it opened itself ('CallerHandle'), which the facility closes only when the call ends before the body is
-- entered. Readers: one owned thread ("Test.Support.Owned") per piped output stream, joined with the scope. Lifetime: the call.
-- Disposal: the release, in the order group, leader, drain, readers, handles.
module Test.Support.Subprocess
  ( -- * Bounds and seams
    RunBound (..)
  , Bounds (..)
  , defaultBounds
  , Seams (..)
  , SignalTarget (..)
  , noSeams
    -- * Failures
  , SubprocessFailure (..)
  , RetainedFailure (..)
    -- * Run to completion
  , Completed (..)
  , Drain (..)
  , runToCompletion
  , runToCompletionUsing
  , runCaptured
  , runCapturedUsing
    -- * A scoped child
  , Stream (..)
  , Placement (..)
  , ChildSpec (..)
  , childSpec
  , withScopedChild
  , withScopedChildUsing
  , Child
  , childProcess
  , childPid
  , childStdin
  , Output (..)
  , Line (..)
  , nextLine
  , captured
  , restOfOutput
  , outputFailure
  , awaitDrain
  , signalChild
  , waitChild
  , ChildState (..)
  , childState
  , awaitUnreapedExit
  , probeGroup
  , describeCommand
  , describeBound
  ) where

import Control.Concurrent (threadDelay, yield)
import Control.Concurrent.STM (TVar, atomically, check, modifyTVar', newTVarIO, readTVar, readTVarIO, writeTVar)
import Control.Exception
  ( Exception (displayException, fromException)
  , ExceptionWithContext (ExceptionWithContext)
  , IOException
  , SomeAsyncException
  , SomeException
  , catch
  , finally
  , interruptible
  , mask
  , onException
  , rethrowIO
  , throwIO
  , try
  , tryWithContext
  , uninterruptibleMask_
  )
import Control.Exception.Annotation (ExceptionAnnotation (displayExceptionAnnotation))
import Control.Exception.Context (addExceptionAnnotation)
import Control.Applicative ((<|>))
import Control.Monad (forM_, unless, void, when)
import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef, writeIORef)
import Data.Maybe (fromMaybe, isJust, isNothing)
import qualified Data.Text as Text
import Data.Text.Encoding (decodeUtf8Lenient)
import Foreign.C.Types (CInt (..))
import GHC.Clock (getMonotonicTimeNSec)
import System.Exit (ExitCode)
import System.IO (Handle, hClose, hPutStr, hPutStrLn, hSetBinaryMode, stderr)
import System.IO.Error (isDoesNotExistError)
import System.Posix.IO (FdOption (CloseOnExec), closeFd, fdToHandle, setFdOption)
import qualified System.Posix.IO as Posix
import System.Posix.Signals (Signal, nullSignal, sigKILL, sigTERM, signalProcess, signalProcessGroup)
import System.Posix.Types (CPid (..), ProcessID)
import System.Process
  ( CmdSpec (RawCommand, ShellCommand)
  , CreateProcess (cmdspec, create_group, cwd, new_session, std_err, std_in, std_out)
  , ProcessHandle
  , StdStream (Inherit, NoStream, UseHandle)
  , createProcess_
  , getPid
  , getProcessExitCode
  , terminateProcess
  , waitForProcess
  )
import System.Timeout (timeout)
import Test.Support.Owned (withOwnedThread)

-- --------------------------------------------------------------------------
-- Bounds, seams and failures

-- | How long, in microseconds, a call may run before it is ended and fails. There is no default: a call says how long it may take,
-- or says that it is human-paced and has no bound.
data RunBound
  = -- | At most this many microseconds. A hang-catcher, never a timing assumption an example's correctness depends on.
    Within !Int
  | -- | Human-paced: no bound on the body. The child is still ended on a failing body and on a cancellation.
    Unbounded
  deriving (Eq, Show)

-- | The facility's own fixed values, in microseconds: how long a child terminated has to exit before its group is killed, how long
-- the reap and the observation that a group is gone are given, and how long the pipes are given to end.
data Bounds = Bounds
  { boundGrace ∷ !Int
  , boundReap ∷ !Int
  , boundDrain ∷ !Int
  }
  deriving (Eq, Show)

-- | Two seconds of grace and ten seconds each to reap and to drain. No production value changes: only the facility's own
-- examples pass others.
defaultBounds ∷ Bounds
defaultBounds = Bounds {boundGrace = 2000000, boundReap = 10000000, boundDrain = 10000000}

-- | The test-side hooks of the facility's own examples. Production use is 'noSeams'; the command under test has none.
data Seams = Seams
  { seamSpawned ∷ ProcessHandle → IO ()
  -- ^ Run in the masked acquisition once the child exists and before the body is entered: what an example raises from to make the
  -- acquisition fail part-way.
  , seamReleasing ∷ IO ()
  -- ^ Run at the start of every attempt of the release, where it can be interrupted: where an example parks the release to deliver
  -- a cancellation into it.
  , seamPoll ∷ ProcessHandle → IO (Maybe ExitCode)
  -- ^ The facility's non-blocking check whether the direct child has been reaped (the library's, which reaps one that has exited).
  , seamWait ∷ ProcessHandle → Int → IO (Maybe ExitCode)
  -- ^ The facility's bounded wait for the direct child, in microseconds. An example that makes it answer 'Nothing' injects a reap
  -- that is not confirmed.
  , seamGroupRemains ∷ ProcessID → IO Bool
  -- ^ Whether any process of the group remains ('probeGroup'). An example that makes it answer 'True' injects a descendant whose end
  -- is not observed.
  , seamDiagnostic ∷ String → IO ()
  -- ^ Where the release writes the cleanup it could not confirm, beside annotating the raised failure with it. A failure of the write
  -- itself is ignored: a diagnostic never replaces the failure being raised.
  , seamSignalled ∷ SignalTarget → Signal → IO ()
  -- ^ Run just before the release sends a signal: what an example reads to say which signals were sent and to what, so that a child
  -- that obeys SIGTERM is shown not to have been sent SIGKILL, and a child that stays in the caller's group is shown to have been
  -- signalled by process identifier only.
  }

-- | What a signal of the release is sent to.
data SignalTarget = ToProcess | ToGroup
  deriving (Eq, Show)

noSeams ∷ Seams
noSeams =
  Seams
    { seamSpawned = \_ → pure ()
    , seamReleasing = pure ()
    , seamPoll = getProcessExitCode
    , seamWait = \handle bound → timeout (max 0 bound) (waitForProcess handle)
    , seamGroupRemains = probeGroup
    , seamDiagnostic = hPutStrLn stderr
    , seamSignalled = \_ _ → pure ()
    }

-- | A failure of the facility's own contract: a run bound that expired, or cleanup that could not be confirmed. The message names
-- the command and says which.
newtype SubprocessFailure = SubprocessFailure String
  deriving (Eq)

instance Show SubprocessFailure where
  show (SubprocessFailure message) = message

instance Exception SubprocessFailure

-- | A failure kept beside the one that is raised, in its exception context, so that neither is lost: the body's failure beside a
-- cancellation, and a cleanup that was not confirmed beside either.
data RetainedFailure = RetainedFailure String String
  deriving (Eq, Show)

instance ExceptionAnnotation RetainedFailure where
  displayExceptionAnnotation (RetainedFailure label text) = label <> ": " <> text

-- --------------------------------------------------------------------------
-- What a call asks for

-- | What a standard stream of the child is.
data Stream
  = -- | A pipe the facility creates and reads (the output streams) or writes (standard input).
    Piped
  | -- | Closed or absent: the child gets no such stream, and the facility never substitutes another for it.
    Absent
  | -- | The caller's own, for a child that talks to a person at the keyboard.
    Inherited
  | -- | A handle the caller opened. It is the caller's to close, except that the facility closes it when the start fails or the call
    -- is cancelled before the body is entered; the caller's own scope closes it on every later exit.
    CallerHandle !Handle

-- | Which process group the child is placed in.
data Placement
  = -- | A process group of its own (never a session of its own), ended whole. The default.
    OwnGroup
  | -- | The caller's, for a child that inherits the terminal for a person at the keyboard and for the nested private compositors that
    -- the outer launcher's deadline must still end. Only the child's process identifier is signalled.
    CallersGroup
  deriving (Eq, Show)

-- | A scoped child. The command, arguments, environment and working directory are the 'CreateProcess' fields; its stream and group
-- fields are ignored in favour of the ones here.
data ChildSpec = ChildSpec
  { specProcess ∷ !CreateProcess
  , specStdin ∷ !Stream
  , specStdout ∷ !Stream
  , specStderr ∷ !Stream
  , specPlacement ∷ !Placement
  , specBound ∷ !RunBound
  }

-- | The usual child: no standard input, both outputs piped, a group of its own. The run bound is stated, never defaulted.
childSpec ∷ RunBound → CreateProcess → ChildSpec
childSpec bound process =
  ChildSpec {specProcess = process, specStdin = Absent, specStdout = Piped, specStderr = Piped, specPlacement = OwnGroup, specBound = bound}

-- | Which of the child's output streams.
data Output = Stdout | Stderr
  deriving (Eq, Show)

-- | The result of waiting for the next line of a stream.
data Line
  = Line String
  | -- | The stream has ended (or was never piped) and every line has been taken.
    EndOfStream
  | -- | The bound given expired first.
    TimedOut
  deriving (Eq, Show)

-- | Whether a pipe ended, as the drain wait answers it.
data Drain = Drained | DrainGivenUp
  deriving (Eq, Show)

-- | What a run to completion answers.
data Completed = Completed
  { completedStatus ∷ !ExitCode
  , completedOut ∷ !String
  , completedErr ∷ !String
  , completedDrain ∷ !Drain
  -- ^ 'DrainGivenUp' when a descendant kept a pipe open after the child exited and the drain bound passed: what was read is kept.
  }
  deriving (Eq, Show)

-- --------------------------------------------------------------------------
-- The scoped child

-- | One piped output stream: what was read, whether the stream has ended, and how much of it the body has taken as lines.
data Reader = Reader
  { readerChunks ∷ !(TVar [ByteString])
  , readerEnded ∷ !(TVar Bool)
  , readerTaken ∷ !(TVar Int)
  , readerFailure ∷ !(TVar (Maybe String))
  }

-- | What the body is lent.
data Child = Child
  { childProcess ∷ !ProcessHandle
  , childPid ∷ !ProcessID
  , childStdin ∷ !(Maybe Handle)
  -- ^ The write end of a piped standard input, closed by the release.
  , childOutReader ∷ !(Maybe Reader)
  , childErrReader ∷ !(Maybe Reader)
  , childDrainBound ∷ !Int
  , childDrainAccounted ∷ !(IORef Bool)
  }

-- | The parent's and the child's ends of the pipes a call created.
data Pipes = Pipes
  { pipesOutRead ∷ !(Maybe Handle)
  , pipesErrRead ∷ !(Maybe Handle)
  , pipesInWrite ∷ !(Maybe Handle)
  , pipesInRead ∷ !(Maybe Handle)
  , pipesOutWrite ∷ !(Maybe Handle)
  , pipesErrWrite ∷ !(Maybe Handle)
  }

-- | 'withScopedChildUsing' with the fixed bounds and no seams.
withScopedChild ∷ ChildSpec → (Child → IO a) → IO a
withScopedChild = withScopedChildUsing defaultBounds noSeams

-- | Start the child, run the body, and on every way out end the child as the module header describes. The call's own run bound
-- ends the body when it expires and fails the call naming the command and the bound.
withScopedChildUsing ∷ Bounds → Seams → ChildSpec → (Child → IO a) → IO a
withScopedChildUsing bounds seams spec body =
  withPipes bounds spec $ \entered pipes →
    withReader (pipesOutRead pipes) $ \outReader →
      withReader (pipesErrRead pipes) $ \errReader →
        withProcess bounds seams spec entered pipes outReader errReader body

-- | Create the pipes and own them (and the caller's handles until the body is entered). A step that fails closes what exists.
--
-- Nothing here can block while uninterruptible. The only close that can wait on the other end of a pipe is a write end holding
-- unflushed bytes: the child's standard input, closed by the release in a bounded, interruptible step ('disposeStdin') before the
-- uninterruptible close below finds it already closed; and a caller's handle, which the facility closes only when the call ends before
-- the body is entered, bounded by the reap bound ('closeCallerHandles'). The other handles closed here are read ends, whose readers
-- were joined first, and the child's ends, which the facility never wrote to.
withPipes ∷ Bounds → ChildSpec → (IORef Bool → Pipes → IO a) → IO a
withPipes bounds spec use = mask $ \restore → do
  entered ← newIORef False
  pipes ← createPipes spec `onException` closeCallerHandles bounds spec
  let cleanup = do
        uninterruptibleMask_ (closePipes pipes)
        wasEntered ← readIORef entered
        unless wasEntered (closeCallerHandles bounds spec)
  restore (use entered pipes) `finally` cleanup

createPipes ∷ ChildSpec → IO Pipes
createPipes spec = do
  created ← newIORef ([] ∷ [Handle])
  let remember handles = atomicModifyIORef' created (\known → (handles <> known, ()))
      -- Output is read as bytes and decoded by the reader; standard input is text, written as the library calls wrote it.
      pipeFor binaryReadEnd stream = case stream of
        Piped → do
          (readFd, writeFd) ← Posix.createPipe
          -- Every end is close-on-exec: the child gets its own end by duplication onto its standard stream, and none of the others
          -- may reach it or any other child this process starts, or a pipe would never end while some child still held its writer.
          (setFdOption readFd CloseOnExec True >> setFdOption writeFd CloseOnExec True) `onException` (closeFd readFd >> closeFd writeFd)
          readEnd ← fdToHandle readFd `onException` (closeFd readFd >> closeFd writeFd)
          writeEnd ← fdToHandle writeFd `onException` (hClose readEnd >> closeFd writeFd)
          remember [readEnd, writeEnd]
          when binaryReadEnd (hSetBinaryMode readEnd True)
          pure (Just (readEnd, writeEnd))
        _ → pure Nothing
  ( do
      input ← pipeFor False (specStdin spec)
      output ← pipeFor True (specStdout spec)
      failures ← pipeFor True (specStderr spec)
      pure
        Pipes
          { pipesOutRead = fst <$> output
          , pipesErrRead = fst <$> failures
          , pipesInWrite = snd <$> input
          , pipesInRead = fst <$> input
          , pipesOutWrite = snd <$> output
          , pipesErrWrite = snd <$> failures
          }
    )
    `onException` (readIORef created >>= mapM_ closeQuietly)

closePipes ∷ Pipes → IO ()
closePipes pipes =
  mapM_
    closeQuietly
    ( concatMap
        (maybe [] pure)
        [pipesOutRead pipes, pipesErrRead pipes, pipesInWrite pipes, pipesInRead pipes, pipesOutWrite pipes, pipesErrWrite pipes]
    )

-- | Close the handles the caller opened, each within the reap bound. A close interrupted by the bound or by a cancellation still closes
-- the descriptor (the handle's own close does that even when its flush is interrupted), discarding what could not be flushed. A
-- cancellation that arrives is remembered, the other handles are closed, and it is raised after them.
closeCallerHandles ∷ Bounds → ChildSpec → IO ()
closeCallerHandles bounds spec = do
  remembered ← newIORef Nothing
  forM_ [specStdin spec, specStdout spec, specStderr spec] $ \case
    CallerHandle handle →
      tryWithContext @SomeException (timeout (max 0 (boundReap bounds)) (hClose handle)) >>= \case
        Left interruption@(ExceptionWithContext _ failure)
          | isJust (fromException failure ∷ Maybe SomeAsyncException) → atomicModifyIORef' remembered (\known → (Just (fromMaybe interruption known), ()))
        _ → pure ()
    _ → pure ()
  readIORef remembered >>= mapM_ rethrowIO

closeQuietly ∷ Handle → IO ()
closeQuietly handle = void (try (hClose handle) ∷ IO (Either IOException ()))

-- | Run the use with a reader of the handle (if there is one) on an owned thread: stopped and joined with the use.
withReader ∷ Maybe Handle → (Maybe Reader → IO a) → IO a
withReader Nothing use = use Nothing
withReader (Just handle) use = do
  chunks ← newTVarIO []
  ended ← newTVarIO False
  taken ← newTVarIO 0
  failure ← newTVarIO Nothing
  let loop = do
        chunk ← ByteString.hGetSome handle 4096
        unless (ByteString.null chunk) $ do
          atomically (modifyTVar' chunks (chunk :))
          loop
      record (failed ∷ IOException) = atomically (writeTVar failure (Just (show failed)))
  withOwnedThread
    ((loop `catch` record) `finally` atomically (writeTVar ended True))
    (\_ _ → use (Just (Reader chunks ended taken failure)))

-- | The state the release works from.
data Env = Env
  { envBounds ∷ !Bounds
  , envSeams ∷ !Seams
  , envSpec ∷ !ChildSpec
  , envChild ∷ !Child
  , envTermSent ∷ !(IORef Bool)
  , envKillSent ∷ !(IORef Bool)
  , envLeaderReaped ∷ !(IORef Bool)
  , envGroupGone ∷ !(IORef Bool)
  -- ^ Set once a probe, made after the leader was reaped, found no member: the identifier may belong to another group from then on, so
  -- nothing is signalled to it again, however often the release is retried.
  , envProblems ∷ !(IORef [String])
  }

withProcess ∷ Bounds → Seams → ChildSpec → IORef Bool → Pipes → Maybe Reader → Maybe Reader → (Child → IO a) → IO a
withProcess bounds seams spec entered pipes outReader errReader body = mask $ \restore → do
  (handle, pid) ← spawn spec pipes
  accounted ← newIORef False
  let child =
        Child
          { childProcess = handle
          , childPid = pid
          , childStdin = pipesInWrite pipes
          , childOutReader = outReader
          , childErrReader = errReader
          , childDrainBound = boundDrain bounds
          , childDrainAccounted = accounted
          }
  env ← Env bounds seams spec child <$> newIORef False <*> newIORef False <*> newIORef False <*> newIORef False <*> newIORef []
  acquired ← tryWithContext @SomeException $ do
    -- The parent's copies of the child's ends go, so that the readers see the end of the stream when the last holder lets go.
    mapM_ closeQuietly (concatMap (maybe [] pure) [pipesInRead pipes, pipesOutWrite pipes, pipesErrWrite pipes])
    seamSpawned seams handle
    -- A cancellation sent during the acquisition may still sit in the scheduler's inbox or in this thread's queue: take it here, still
    -- masked, where the facility owns everything and the release runs. Left to arrive when the mask is lifted it could land after
    -- the body had begun, and the caller's handles would then be the caller's to close.
    yield
    interruptible (pure ())
  outcome ← case acquired of
    Left failure → pure (Left failure)
    Right () →
      -- The body is entered when it is running, not when the mask is about to be lifted: a cancellation queued during the acquisition is
      -- delivered the moment the mask is lifted, before anything of the body ran, and the caller's handles are then still the
      -- facility's to close. The flag is therefore set by the first step inside the restored state.
      let entering = writeIORef entered True >> body child
       in tryWithContext @SomeException $ case specBound spec of
            Unbounded → Just <$> restore entering
            Within microseconds → timeout (max 0 microseconds) (restore entering)
  conclude env outcome

-- | Create the process in one step with its identifier read. The caller's handles are not closed by the library.
spawn ∷ ChildSpec → Pipes → IO (ProcessHandle, ProcessID)
spawn spec pipes = do
  let stream choice childEnd = case choice of
        Piped → maybe NoStream UseHandle childEnd
        Absent → NoStream
        Inherited → Inherit
        CallerHandle handle → UseHandle handle
  (_, _, _, handle) ←
    createProcess_
      "Test.Support.Subprocess"
      (specProcess spec)
        { cwd = rootSpelling <$> cwd (specProcess spec)
        , std_in = stream (specStdin spec) (pipesInRead pipes)
        , std_out = stream (specStdout spec) (pipesOutWrite pipes)
        , std_err = stream (specStderr spec) (pipesErrWrite pipes)
        , create_group = specPlacement spec == OwnGroup
        , new_session = False
        }
  getPid handle >>= \case
    Just pid → pure (handle, pid)
    Nothing → do
      terminateProcess handle
      void (waitForProcess handle)
      ioError (userError ("the child " <> describeCommand (specProcess spec) <> " had been reaped before its identifier was read"))

-- | The same directory spelled so that the @process@ library can start a child there. On a platform without @execvpe@ (macOS), a child
-- that is given an environment, a process group of its own and the working directory @\"/\"@ spelled exactly so fails in the library
-- with "chdir: does not exist" (@process-1.6.26.1@, reproduced with @readCreateProcessWithExitCode@ itself); @\"/.\"@ is the same
-- directory and starts. Every other spelling is passed through as it is.
rootSpelling ∷ FilePath → FilePath
rootSpelling directory = if directory == "/" then "/." else directory

-- | Release the child, then raise or answer the outcome with what the release found. Called masked.
--
-- A cancellation remembered by the release is raised after it, with the failure of what was being run retained beside it;
-- otherwise a failure is raised as itself, an expired run bound fails the call naming the command and the bound, and a cleanup that
-- could not be confirmed fails an otherwise passing outcome.
conclude ∷ Env → Either (ExceptionWithContext SomeException) (Maybe a) → IO a
conclude env outcome = do
  (problems, releaseInterruption) ← release env
  -- A diagnostic, written where a person reads the run. It is part of the release's cancellation handling: a cancellation that arrives
  -- while it is written is remembered and raised after, like any other, with the failure being raised retained beside it; a stream that
  -- fails or does not take the write within the reap bound is given up on, because a diagnostic never replaces the failure being raised.
  remaining ← newIORef problems
  let writeAll =
        readIORef remaining >>= \case
          [] → pure ()
          text : rest → do
            void
              ( timeout
                  (max 0 (boundReap (envBounds env)))
                  (try (seamDiagnostic (envSeams env) ("Test.Support.Subprocess: the cleanup was not confirmed: " <> text)) ∷ IO (Either IOException ()))
              )
            writeIORef remaining rest
            writeAll
  written ← rememberingInterruption writeAll
  let interruption = releaseInterruption <|> written
  let command = describeCommand (specProcess (envSpec env))
      retainProblems primary = foldl (\acc text → annotate (RetainedFailure "the cleanup was not confirmed" text) acc) primary problems
  case (interruption, outcome) of
    (Just interrupted, Left failure) → rethrowIO (retainProblems (retain "the failure of what was being run" failure interrupted))
    (Just interrupted, Right _) → rethrowIO (retainProblems interrupted)
    (Nothing, Left failure) → rethrowIO (retainProblems failure)
    (Nothing, Right Nothing) →
      throwIO
        ( SubprocessFailure
            ( command
                <> " did not finish within its run bound of "
                <> describeBound (specBound (envSpec env))
                <> "; it was ended"
                <> unconfirmed problems
            )
        )
    (Nothing, Right (Just result)) → do
      unless (null problems) $ throwIO (SubprocessFailure (command <> " was not cleaned up" <> unconfirmed problems))
      pure result
  where
    unconfirmed problems = if null problems then "" else " (the cleanup was not confirmed: " <> unwords' problems <> ")"
    unwords' = foldr1 (\a b → a <> "; " <> b)

annotate ∷ RetainedFailure → ExceptionWithContext SomeException → ExceptionWithContext SomeException
annotate retained (ExceptionWithContext context failure) = ExceptionWithContext (addExceptionAnnotation retained context) failure

retain ∷ String → ExceptionWithContext SomeException → ExceptionWithContext SomeException → ExceptionWithContext SomeException
retain label (ExceptionWithContext _ inner) = annotate (RetainedFailure label (displayException inner))

-- | End the child, observe the group, wait for the pipes; answer what could not be confirmed and the first cancellation that
-- interrupted the waits (the steps are run again until they complete).
release ∷ Env → IO ([String], Maybe (ExceptionWithContext SomeException))
release env = do
  interruption ← rememberingInterruption $ do
    seamReleasing (envSeams env)
    endChild env
    disposeStdin env
    drainForRelease env
  problems ← readIORef (envProblems env)
  pure (reverse problems, interruption)

rememberingInterruption ∷ IO () → IO (Maybe (ExceptionWithContext SomeException))
rememberingInterruption act = go Nothing
  where
    go pending =
      tryWithContext @SomeException act >>= \case
        Right () → pure pending
        Left interruption@(ExceptionWithContext _ failure)
          | isJust (fromException failure ∷ Maybe SomeAsyncException) → go (Just (fromMaybe interruption pending))
          | otherwise → rethrowIO interruption

noteProblem ∷ Env → String → IO ()
noteProblem env text = atomicModifyIORef' (envProblems env) (\known → (if text `elem` known then known else text : known, ()))

once ∷ IORef Bool → IO () → IO ()
once flag act = do
  done ← readIORef flag
  unless done (writeIORef flag True >> act)

-- | End the child: SIGTERM, wait out the grace, SIGKILL, confirm the reap; and for a child in a group of its own, the group.
endChild ∷ Env → IO ()
endChild env = case specPlacement (envSpec env) of
  OwnGroup → endGroup env
  CallersGroup → endPid env

handleOf ∷ Env → ProcessHandle
handleOf = childProcess . envChild

-- | Poll, then wait: whether the direct child is known to be reaped.
pollLeader ∷ Env → IO Bool
pollLeader env = do
  known ← readIORef (envLeaderReaped env)
  if known
    then pure True
    else do
      status ← seamPoll (envSeams env) (handleOf env)
      when (isJust status) $ writeIORef (envLeaderReaped env) True
      pure (isJust status)

-- | A bounded wait for the direct child; whether the reap was confirmed.
awaitLeader ∷ Env → Int → IO Bool
awaitLeader env microseconds = do
  status ← seamWait (envSeams env) (handleOf env) microseconds
  when (isJust status) $ writeIORef (envLeaderReaped env) True
  pure (isJust status)

-- | Send a signal to the child's process or to its group, once the seam has been told. A target that is already gone is not an error.
sendTo ∷ Env → SignalTarget → Signal → IO ()
sendTo env target signal = do
  seamSignalled (envSeams env) target signal
  let pid = childPid (envChild env)
  void (try (case target of ToProcess → signalProcess signal pid; ToGroup → signalProcessGroup signal pid) ∷ IO (Either IOException ()))

-- | A child that stays in the caller's group: its identifier alone is signalled, only while it is unreaped (so the identifier is
-- still its own).
endPid ∷ Env → IO ()
endPid env = do
  reaped ← pollLeader env
  unless reaped $ do
    let bounds = envBounds env
    once (envTermSent env) (sendTo env ToProcess sigTERM)
    exited ← awaitLeader env (boundGrace bounds)
    unless exited $ do
      once (envKillSent env) (sendTo env ToProcess sigKILL)
      confirmed ← awaitLeader env (boundReap bounds)
      unless confirmed $ noteProblem env ("the child was not reaped within " <> describeBound (Within (boundReap bounds)) <> " of SIGKILL")

-- | A child that leads a process group of its own: the whole group is ended, whether or not the leader has already exited.
endGroup ∷ Env → IO ()
endGroup env = do
  let pid = childPid (envChild env)
      bounds = envBounds env
      remains = probeFor env
  leaderReaped ← pollLeader env
  -- While the leader is unreaped its identifier cannot belong to another group, so the group may be signalled. Once it is reaped the
  -- group is signalled only while a member is known to remain; a null signal that finds none sends nothing.
  groupKnown ← if leaderReaped then remains pid else pure True
  when groupKnown $ once (envTermSent env) (sendTo env ToGroup sigTERM)
  unless leaderReaped $ do
    exited ← awaitLeader env (boundGrace bounds)
    unless exited $ do
      once (envKillSent env) (sendTo env ToGroup sigKILL)
      confirmed ← awaitLeader env (boundReap bounds)
      unless confirmed $ noteProblem env ("the child was not reaped within " <> describeBound (Within (boundReap bounds)) <> " of SIGKILL")
  confirmedReaped ← readIORef (envLeaderReaped env)
  when confirmedReaped $ do
    stillThere ← remains pid
    when stillThere $ do
      killed ← readIORef (envKillSent env)
      -- Members that obey SIGTERM are given the rest of the grace; ones that outlast it are killed, once, and then waited for. A group
      -- that has already been sent SIGKILL (the leader outlasted the grace) is only waited for: its members are zombies awaiting their
      -- adopter, and a second signal would add nothing.
      gone ← if killed then pure False else groupGone remains pid (boundGrace bounds)
      unless gone $ do
        unless killed $
          -- A member is known to remain (the probe just said so), so the identifier is still reserved.
          once (envKillSent env) (sendTo env ToGroup sigKILL)
        vanished ← groupGone remains pid (boundReap bounds)
        unless vanished $
          noteProblem env ("processes of the child's process group still remained " <> describeBound (Within (boundReap bounds)) <> " after SIGKILL (a zombie awaiting its parent counts as remaining)")

-- | The probe the release signals on, made only once the leader is reaped: whether a member remains. The first answer of "none" is
-- terminal. The identifier of a group with no member can be given to an unrelated one, so from then on this answers "none" without
-- asking again, and the release sends the group nothing.
probeFor ∷ Env → ProcessID → IO Bool
probeFor env pgid = do
  already ← readIORef (envGroupGone env)
  if already
    then pure False
    else do
      present ← seamGroupRemains (envSeams env) pgid
      unless present $ writeIORef (envGroupGone env) True
      pure present

-- | Whether a null signal to the group finds a member. A member that exists but may not be signalled counts as remaining, as does a
-- zombie.
probeGroup ∷ ProcessID → IO Bool
probeGroup pgid =
  (signalProcessGroup nullSignal pgid >> pure True)
    `catch` \(failure ∷ IOException) → pure (not (isDoesNotExistError failure))

-- | Wait for the group to be gone, for at most the bound. The operating system has no event for a zombie's adoption, so this is the
-- one place the facility polls; it observes the world, it coordinates no thread, and the bound is only a timeout.
groupGone ∷ (ProcessID → IO Bool) → ProcessID → Int → IO Bool
groupGone remains pgid microseconds = do
  start ← getMonotonicTimeNSec
  let limit = fromIntegral (max 0 microseconds) * 1000
      loop = do
        present ← remains pgid
        if not present
          then pure True
          else do
            now ← getMonotonicTimeNSec
            if now - start >= limit then pure False else threadDelay 2000 >> loop
  loop

-- | Close the piped standard input, within the reap bound and where a cancellation can reach it. Closing flushes what the body left
-- buffered, and that waits for whoever holds the read end: a descendant outside the group that does not read it keeps the flush
-- waiting for ever. Interrupted by the bound the close still closes the descriptor and drops the buffer (the handle's own close does
-- that), and the bound passing is a cleanup that was not confirmed, said beside whatever else the call raises.
disposeStdin ∷ Env → IO ()
disposeStdin env = forM_ (childStdin (envChild env)) $ \handle → do
  let bound = boundReap (envBounds env)
  closed ← timeout (max 0 bound) (try (hClose handle) ∷ IO (Either IOException ()))
  when (isNothing closed) $
    noteProblem env ("the child's standard input could not be flushed and closed within " <> describeBound (Within bound) <> ": a holder of its read end outside the child's group is not reading it, so the unflushed input was discarded")

-- | Wait for the pipes to end, once the child and its group have been ended, and say so when they did not. A call that has already
-- given its own account of the drain ('awaitDrain') is not failed for it again.
drainForRelease ∷ Env → IO ()
drainForRelease env = do
  accounted ← readIORef (childDrainAccounted (envChild env))
  unless accounted $ do
    result ← awaitDrain (envChild env)
    when (result == DrainGivenUp) $
      noteProblem env ("the child's pipes did not end within " <> describeBound (Within (boundDrain (envBounds env))) <> " of the end of the child")
  -- A stream that stopped for a reason other than reaching its end lost output the body may have relied on: it is evidence, not silence.
  forM_ [(Stdout, "standard output"), (Stderr, "standard error")] $ \(output, name) →
    outputFailure (envChild env) output >>= mapM_ (\failure → noteProblem env ("the child's " <> name <> " stopped before its end: " <> failure))

-- --------------------------------------------------------------------------
-- What the body can do

-- | Wait, within the bound in microseconds, for the next line of a piped stream, as it arrives. A stream that was not piped has
-- ended.
nextLine ∷ Child → Output → Int → IO Line
nextLine child output microseconds = case readerFor child output of
  Nothing → pure EndOfStream
  Just reader →
    maybe TimedOut id <$> timeout (max 0 microseconds) (atomically (takeLine reader))
  where
    takeLine reader = do
      chunks ← readTVar (readerChunks reader)
      taken ← readTVar (readerTaken reader)
      let rest = ByteString.drop taken (ByteString.concat (reverse chunks))
      case ByteString.elemIndex 10 rest of
        Just newline → do
          writeTVar (readerTaken reader) (taken + newline + 1)
          pure (Line (decode (ByteString.take newline rest)))
        Nothing → do
          ended ← readTVar (readerEnded reader)
          check ended
          if ByteString.null rest
            then pure EndOfStream
            else do
              writeTVar (readerTaken reader) (taken + ByteString.length rest)
              pure (Line (decode rest))

readerFor ∷ Child → Output → Maybe Reader
readerFor child = \case
  Stdout → childOutReader child
  Stderr → childErrReader child

decode ∷ ByteString → String
decode = Text.unpack . decodeUtf8Lenient

-- | Wait, within the bound in microseconds, for a piped stream to end and answer what the body has not yet taken as lines, to its end.
-- 'Nothing' when the stream had not ended within the bound. A stream that was not piped answers nothing to read.
restOfOutput ∷ Child → Output → Int → IO (Maybe String)
restOfOutput child output microseconds = case readerFor child output of
  Nothing → pure (Just "")
  Just reader →
    timeout (max 0 microseconds) . atomically $ do
      readTVar (readerEnded reader) >>= check
      chunks ← readTVar (readerChunks reader)
      taken ← readTVar (readerTaken reader)
      let everything = ByteString.concat (reverse chunks)
      writeTVar (readerTaken reader) (ByteString.length everything)
      pure (decode (ByteString.drop taken everything))

-- | Everything a stream has delivered so far.
captured ∷ Child → Output → IO String
captured child output = case readerFor child output of
  Nothing → pure ""
  Just reader → decode . ByteString.concat . reverse <$> readTVarIO (readerChunks reader)

-- | Why a piped stream stopped, when it stopped for any reason other than reaching its end.
outputFailure ∷ Child → Output → IO (Maybe String)
outputFailure child output = maybe (pure Nothing) (readTVarIO . readerFailure) (readerFor child output)

-- | Wait for every piped stream to end, for at most the drain bound. This is the call's own account of the drain: a descendant that
-- keeps a pipe open after the child has exited is given up on, what was read is kept, and the answer says so.
awaitDrain ∷ Child → IO Drain
awaitDrain child = do
  let readers = concatMap (maybe [] pure) [childOutReader child, childErrReader child]
  result ← timeout (max 0 (childDrainBound child)) (atomically (forM_ readers (\reader → readTVar (readerEnded reader) >>= check)))
  writeIORef (childDrainAccounted child) True
  pure (maybe DrainGivenUp (const Drained) result)

-- | Send a signal to the child's process identifier (not its group), unless the child has been reaped, when the identifier may be
-- another process's.
signalChild ∷ Child → Signal → IO ()
signalChild child signal = do
  status ← getProcessExitCode (childProcess child)
  when (isNothing status) $ signalProcess signal (childPid child)

-- | Wait, within the bound in microseconds, for the child's exit, which reaps it.
waitChild ∷ Child → Int → IO (Maybe ExitCode)
waitChild child microseconds = timeout (max 0 microseconds) (waitForProcess (childProcess child))

-- | Where the child is, as a look that does not reap it.
data ChildState
  = StillRunning
  | -- | Exited, and not reaped: a zombie, which the release reaps.
    ExitedUnreaped
  | -- | Not a child of this process any more: reaped.
    Reaped
  deriving (Eq, Show)

foreign import ccall interruptible "hetoimasia_test_support_child_state"
  c_childState ∷ CPid → CInt → IO CInt

-- | Ask whether the child has exited, without reaping it (waitid with WNOWAIT), so a body can observe a zombie.
childState ∷ Child → IO ChildState
childState child =
  observeState (childPid child) False >>= \case
    Right state → pure state
    Left errno
      | errno == eCHILD → pure Reaped
      | otherwise → ioError (userError ("waitid for process " <> show (childPid child) <> " failed with errno " <> show errno))

observeState ∷ ProcessID → Bool → IO (Either CInt ChildState)
observeState pid block = do
  answer ← c_childState (CPid (fromIntegral pid)) (if block then 1 else 0)
  pure $ case answer of
    1 → Right ExitedUnreaped
    0 → Right StillRunning
    failure → Left (negate failure)

-- | Wait, within the bound in microseconds, for the child to have exited, without reaping it. 'Nothing' when the bound expired.
awaitUnreapedExit ∷ Child → Int → IO (Maybe ChildState)
awaitUnreapedExit child microseconds = timeout (max 0 microseconds) loop
  where
    loop =
      observeState (childPid child) True >>= \case
        Right state → pure state
        Left errno
          | errno == eINTR → loop
          | errno == eCHILD → pure Reaped
          | otherwise → ioError (userError ("waitid for process " <> show (childPid child) <> " failed with errno " <> show errno))

eINTR, eCHILD ∷ CInt
eINTR = 4
eCHILD = 10

-- --------------------------------------------------------------------------
-- Run to completion

-- | Run a command to completion and answer how it ended and everything it wrote, with the fixed bounds.
runToCompletion ∷ RunBound → CreateProcess → String → IO Completed
runToCompletion = runToCompletionUsing defaultBounds noSeams

-- | 'runToCompletion' with the given bounds and seams (the facility's own examples).
--
-- The command's standard input is the given string, then closed. Both outputs are read as the child writes them. If the run bound
-- expires the child is ended and the call fails naming the command and the bound.
runToCompletionUsing ∷ Bounds → Seams → RunBound → CreateProcess → String → IO Completed
runToCompletionUsing bounds seams bound process input =
  withScopedChildUsing bounds seams (childSpec bound process) {specStdin = Piped} (complete input)

-- | What a run to completion does with a child whose standard input is piped: give it the input and the end of it, wait for it to
-- exit, give up on pipes a descendant keeps open past the drain bound, and answer.
complete ∷ String → Child → IO Completed
complete input child = feeding $ do
  status ← waitForProcess (childProcess child)
  drain ← awaitDrain child
  out ← captured child Stdout
  err ← captured child Stderr
  pure Completed {completedStatus = status, completedOut = out, completedErr = err, completedDrain = drain}
  where
    feeding run = case childStdin child of
      Nothing → run
      Just stdinHandle
        | null input → closeQuietly stdinHandle >> run
        | otherwise →
            withOwnedThread
              ((hPutStr stdinHandle input >> closeQuietly stdinHandle) `catch` \(_ ∷ IOException) → closeQuietly stdinHandle)
              (\_ _ → run)

-- | 'runToCompletion', answering the triple the one-shot library calls answered. A drain that was given up on fails the call (those
-- calls would have hung), and says what was read.
runCaptured ∷ RunBound → CreateProcess → String → IO (ExitCode, String, String)
runCaptured = runCapturedUsing defaultBounds noSeams

-- | 'runCaptured' with the given bounds and seams (the facility's own examples).
runCapturedUsing ∷ Bounds → Seams → RunBound → CreateProcess → String → IO (ExitCode, String, String)
runCapturedUsing bounds seams bound process input = do
  Completed {completedStatus = status, completedOut = out, completedErr = err, completedDrain = drain} ← runToCompletionUsing bounds seams bound process input
  case drain of
    Drained → pure (status, out, err)
    DrainGivenUp →
      throwIO
        ( SubprocessFailure
            ( describeCommand process
                <> " exited, but a descendant kept its output open past the drain bound of "
                <> describeBound (Within (boundDrain bounds))
                <> "; read so far: "
                <> show out
                <> " and on stderr "
                <> show err
            )
        )


-- --------------------------------------------------------------------------
-- Naming

-- | The command a failure names.
describeCommand ∷ CreateProcess → String
describeCommand process = clip $ case cmdspec process of
  ShellCommand command → command
  RawCommand program arguments → unwords (program : arguments)
  where
    clip text = if length text > 200 then take 200 text <> "…" else text

-- | A bound as a failure names it.
describeBound ∷ RunBound → String
describeBound = \case
  Unbounded → "no limit"
  Within microseconds
    | microseconds `mod` 1000000 == 0 -> show (microseconds `div` 1000000) <> " s"
    | microseconds `mod` 1000 == 0 -> show (microseconds `div` 1000) <> " ms"
    | otherwise -> show microseconds <> " µs"
