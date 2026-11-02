-- | Hspec coverage for the shared subprocess facility (#588, "Test.Support.Subprocess").
--
-- The facility is the one way a test starts a subprocess: however the scope that started the child ends, the child (and its
-- process group) has been ended, and reaped with the wait confirmed, before the scope returns or raises. These examples are
-- device-free and deterministic. Every child is an @/bin/sh@ command; every wait is a line the child writes, a gate or an MVar, so
-- no example sleeps to coordinate anything, and a bound exists only to keep a stuck example from hanging the run. The facility's
-- own examples shorten its grace through its explicit 'Bounds' argument; the 10 s reap and drain values and the 2 s grace are the
-- ones in force wherever an example does not name others.
--
-- /Judgement./ A child counts as ended only when it is gone and reaped: a zombie still answers the null signal, so only a null
-- signal that fails with "no such process" ('goneAndReaped') says so.
--
-- /Negative controls./ The examples that demonstrate an ownership or timeout regression (the cancellation, run-bound,
-- SIGTERM-ignoring, descendant-in-group, scoped-child cleanup and outer-owner-termination ones) each have a control: the same
-- judgement applied to the library call the converted sites used (@readCreateProcessWithExitCode@, @withCreateProcess@, or a start
-- with no release at all) must fail. A control records its failed judgement first and then stops and reaps whatever it left, even
-- if an assertion fails ('rescue'), so it leaves no debt for a later example. The remaining examples (output capture, stream
-- choices, deferred reap, handle ownership, the run-bound-required check, the guard) are compatibility or contract examples that a
-- library call could not truthfully fail, and have none.
module OwnedSubprocess (spec, ownerMain, ownerVariable) where

import Control.Concurrent (myThreadId, throwTo, yield)
import Control.Concurrent.MVar (MVar, newEmptyMVar, putMVar, readMVar, tryPutMVar)
import Control.Exception
  ( AsyncException (UserInterrupt)
  , Exception
  , ExceptionWithContext (ExceptionWithContext)
  , IOException
  , MaskingState (Unmasked)
  , SomeException
  , catch
  , finally
  , fromException
  , getMaskingState
  , throwIO
  , try
  )
import Control.Exception.Context (getExceptionAnnotations)
import Control.Monad (forM_, void, when)
import Data.Foldable (for_)
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef, writeIORef)
import Data.List (isInfixOf)
import Data.Maybe (fromMaybe)
import Sandbox (run, sanitizedEnvironment)
import System.Directory (canonicalizePath, doesFileExist)
import System.Environment (getEnvironment, getExecutablePath)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO (Handle, IOMode (ReadWriteMode, WriteMode), hClose, hFlush, hGetLine, hIsOpen, openFile, stdout)
import System.IO.Temp (withSystemTempDirectory)
import System.Posix.IO (OpenFileFlags (nonBlock), OpenMode (ReadWrite), defaultFileFlags, fdToHandle, openFd)
import System.Posix.Files (createNamedPipe, ownerModes)
import System.Posix.Process (getProcessGroupID, getProcessGroupIDOf)
import System.Posix.Signals (nullSignal, sigKILL, sigTERM, signalProcess, signalProcessGroup)
import System.Posix.Types (CPid (CPid), ProcessGroupID, ProcessID)
import System.Process
  ( CreateProcess (cwd, env, std_err, std_in, std_out)
  , StdStream (CreatePipe, NoStream)
  , ProcessHandle
  , createProcess
  , getPid
  , proc
  , readCreateProcessWithExitCode
  , waitForProcess
  , withCreateProcess
  )
import System.Timeout (timeout)
import Test.Hspec (Spec, describe, expectationFailure, it, pendingWith, shouldBe, shouldContain, shouldNotContain, shouldSatisfy)
import Test.Support.Bounded (bounded)
import Test.Support.Cancel (awaitBlockedSending, withCancellationAfter)
import Test.Support.Owned (withOwnedThread)
import Test.Support.Parked (defaultParkBounds, parkedRelease)
import Test.Support.Subprocess

-- --------------------------------------------------------------------------
-- Support

-- | The failure an example raises from a body, told apart from every other.
data Boom = Boom
  deriving (Eq, Show)

instance Exception Boom

-- | Raise it from a body whose result nobody uses.
boom ∷ IO ()
boom = throwIO Boom

-- | The facility's bounds as the examples run it: the default reap and drain, and a grace short enough that a child which ignores
-- SIGTERM does not make every example wait the fixed 2 s. The grace is only a timeout, so a shorter one changes how soon a stubborn
-- child is killed, never whether it is.
quick ∷ Bounds
quick = defaultBounds {boundGrace = 100000}

-- | A hang-catcher for a call the example expects to return.
hangCatcher ∷ RunBound
hangCatcher = Within (60 * 1000000)

-- | Is the process gone and reaped? A zombie still answers the null signal, so only "no such process" says so.
goneAndReaped ∷ ProcessID → IO Bool
goneAndReaped pid = (signalProcess nullSignal pid >> pure False) `catch` \(failure ∷ IOException) → pure (isNoSuchProcess failure)
  where
    isNoSuchProcess = isDoesNotExist

isDoesNotExist ∷ IOException → Bool
isDoesNotExist failure = "does not exist" `isInfixOf` show failure || "No such process" `isInfixOf` show failure

-- | Wait, without sleeping, until a process is gone and reaped: for one a detached reaper or the system's adopter reaps. A yielding
-- poll under a bound, the bound being only a timeout.
awaitGone ∷ ProcessID → IO Bool
awaitGone pid = maybe False id <$> timeout (10 * 1000000) loop
  where
    loop = goneAndReaped pid >>= \gone → if gone then pure True else yield >> loop

-- | Kill whatever an example left, by identifier (the library calls never create a group), and wait for it to be reaped. Run by a
-- control after it has recorded its failed judgement, even when an assertion failed.
rescue ∷ [ProcessID] → IO ()
rescue pids = forM_ pids $ \pid → do
  void (try (signalProcess sigKILL pid) ∷ IO (Either IOException ()))
  void (awaitGone pid)

-- | A line-oriented channel from a child to the example that needs no body: a named pipe, opened for reading and writing so that a
-- child opening it to write finds a reader and the example never sees its end. Reading is by the runtime's I/O manager, so it is
-- bounded and killable.
withChannel ∷ FilePath → (FilePath → IO String → IO a) → IO a
withChannel directory use = do
  let path = directory </> "channel"
  createNamedPipe path ownerModes
  fd ← openFd path ReadWrite defaultFileFlags {nonBlock = True}
  handle ← fdToHandle fd
  let next = fromMaybe (error "the child said nothing within 30 s") <$> timeout (30 * 1000000) (hGetLine handle)
  use path next `finally` hClose handle

-- | What an example learns of the children it started.
data Probe = Probe
  { probePids ∷ IORef [ProcessID]
  , probeHandles ∷ IORef [ProcessHandle]
  -- ^ The handles of children a control started and nothing owns, so that its rescue can reap them.
  , probeReady ∷ MVar ()
  }

newProbe ∷ IO Probe
newProbe = Probe <$> newIORef [] <*> newIORef [] <*> newEmptyMVar

-- | A control's rescue: kill what it left, reap it, and wait until it is gone. Run after the control recorded its judgement, even when
-- an assertion failed.
rescueProbe ∷ Probe → IO ()
rescueProbe probe = do
  pids ← readIORef (probePids probe)
  handles ← readIORef (probeHandles probe)
  forM_ pids $ \pid → void (try (signalProcess sigKILL pid) ∷ IO (Either IOException ()))
  forM_ handles $ \handle → timeout (10 * 1000000) (waitForProcess handle)
  forM_ pids awaitGone

remember ∷ Probe → ProcessID → IO ()
remember probe pid = atomicModifyIORef' (probePids probe) (\known → (pid : known, ()))

-- | The shell commands the examples run. Each is given the path of a file the descendant it starts writes its identifier to.
--
-- A leader and a descendant that both ignore SIGTERM, in one process group; the leader says "ready" once the descendant has
-- announced itself, so a signal is never sent before the traps exist. The descendant holds no output pipe.
stubbornPair ∷ String
stubbornPair =
  unlines
    [ "trap '' TERM"
    , "sh -c 'trap \"\" TERM; echo $$ > \"$1.t\"; mv \"$1.t\" \"$1\"; while :; do sleep 1; done' sh \"$1\" >/dev/null 2>&1 &"
    , "while [ ! -e \"$1\" ]; do :; done"
    , "echo \"ready $$\""
    , "while :; do sleep 1; done"
    ]

-- | The leader exits when it is sent SIGTERM; its descendant ignores it.
leaderExitingOnTerm ∷ String
leaderExitingOnTerm =
  unlines
    [ "trap 'exit 0' TERM"
    , "sh -c 'trap \"\" TERM; echo $$ > \"$1.t\"; mv \"$1.t\" \"$1\"; while :; do sleep 1; done' sh \"$1\" >/dev/null 2>&1 &"
    , "while [ ! -e \"$1\" ]; do :; done"
    , "echo \"ready $$\""
    , "while :; do sleep 1; done"
    ]

-- | The leader exits by itself, normally, leaving a descendant that ignores SIGTERM.
leaderExitingNormally ∷ String
leaderExitingNormally =
  unlines
    [ "sh -c 'trap \"\" TERM; echo $$ > \"$1.t\"; mv \"$1.t\" \"$1\"; while :; do sleep 1; done' sh \"$1\" >/dev/null 2>&1 &"
    , "while [ ! -e \"$1\" ]; do :; done"
    , "echo \"ready $$\""
    ]

-- | A lone child that ignores SIGTERM.
stubbornAlone ∷ String
stubbornAlone = "trap '' TERM; echo \"ready $$\"; while :; do sleep 1; done"

-- | A lone child that exits when it is sent SIGTERM.
obedientAlone ∷ String
obedientAlone = "trap 'exit 0' TERM; echo \"ready $$\"; while :; do sleep 1; done"

shell ∷ String → [String] → CreateProcess
shell script arguments = proc "sh" ("-c" : script : "sh" : arguments)

-- | Read the lines a scoped child writes until it says it is ready, within 30 s.
awaitReady ∷ Child → IO ()
awaitReady child =
  nextLine child Stdout (30 * 1000000) >>= \case
    Line text | "ready" `isInfixOf` text → pure ()
    Line _ → awaitReady child
    other → expectationFailure ("the child did not say it was ready: " <> show other)

-- | The identifier the descendant wrote to the file, once the leader has said it is ready.
descendantPid ∷ FilePath → IO ProcessID
descendantPid file = CPid . read <$> readFile file

-- | Wait where only the example's own end can reach it. The wait is bounded by the caller's timeout or 'bounded'.
holdUntilEnded ∷ IO ()
holdUntilEnded = newEmptyMVar >>= \hold → readMVar hold `finally` void (tryPutMVar hold ())

-- --------------------------------------------------------------------------
-- The ways a scope that started a child can end

-- | How a scope that started a child is made to end.
data Ending = Returns | Raises | TimesOut | Cancelled | CancelledStarting | AcquisitionFails | ReleaseParked
  deriving (Eq, Show)

endings ∷ [(String, Ending)]
endings =
  [ ("returns normally", Returns)
  , ("raises from its body", Raises)
  , ("passes its run bound", TimesOut)
  , ("is cancelled in its body", Cancelled)
  , ("is cancelled while the child is being started", CancelledStarting)
  , ("fails after the child exists", AcquisitionFails)
  , ("is cancelled while its release is parked", ReleaseParked)
  ]

-- | The things an ending is judged by: every identifier the scope started (the leader, and the descendant when there is one).
type Scope = FilePath → Probe → Ending → IO ()

-- | Learn the child: remember its identifier, wait for it to be ready, and remember its descendant's.
prepare ∷ FilePath → Probe → Bool → Child → IO ()
prepare file probe withDescendant child = do
  remember probe (childPid child)
  awaitReady child
  when withDescendant $ descendantPid file >>= remember probe
  void (tryPutMVar (probeReady probe) ())

-- | The facility, run to the ending. The outcome of every ending is asserted as it is raised.
facilityScope ∷ String → Bool → Scope
facilityScope script withDescendant directory probe ending = do
  let file = directory </> "descendant"
      process = shell script [file]
      scoped bound seams = withScopedChildUsing quick seams (childSpec bound process)
      body = prepare file probe withDescendant
  case ending of
    Returns → scoped hangCatcher noSeams body
    Raises → do
      outcome ← try @Boom (scoped hangCatcher noSeams (\child → body child >> boom))
      outcome `shouldBe` Left Boom
    TimesOut → do
      outcome ← try @SubprocessFailure (scoped (Within 1000000) noSeams (\child → body child >> holdUntilEnded))
      case outcome of
        Left (SubprocessFailure message) → do
          message `shouldContain` "sh"
          message `shouldContain` "run bound of 1 s"
        Right () → expectationFailure "the run bound did not fail the call"
    Cancelled → do
      outcome ← try @AsyncException (bounded (withCancellationAfter (readMVar (probeReady probe)) (pure ()) (scoped hangCatcher noSeams (\child → body child >> holdUntilEnded))))
      outcome `shouldBe` Left UserInterrupt
    CancelledStarting → do
      -- Delivered in the masked acquisition, after the child exists and before the body is entered.
      let seams = noSeams {seamSpawned = \handle → getPid handle >>= maybe (pure ()) (remember probe) >> throwIO UserInterrupt}
      outcome ← try @AsyncException (scoped hangCatcher seams (\_ → pure ()))
      outcome `shouldBe` Left UserInterrupt
    AcquisitionFails → do
      let seams = noSeams {seamSpawned = \handle → getPid handle >>= maybe (pure ()) (remember probe) >> boom}
      outcome ← try @Boom (scoped hangCatcher seams (\_ → pure ()))
      outcome `shouldBe` Left Boom
    ReleaseParked → do
      outcome ← parkedRelease defaultParkBounds $ \park →
        scoped hangCatcher noSeams {seamReleasing = park} (\child → body child >> boom)
      outcome `shouldSatisfy` cancellation
      -- The body's failure is not lost: it is retained beside the cancellation, in the raised exception's context.
      outcome `shouldSatisfy` retainsBodyFailure

-- | The library call a converted site used to make, run to the same ending: the control's scope.
libraryScope ∷ String → Bool → Scope
libraryScope script withDescendant directory probe ending = do
  let file = directory </> "descendant"
      process = (shell script [file]) {std_in = NoStream, std_out = CreatePipe, std_err = CreatePipe}
      scoped = withCreateProcess process
      body (_, out, _, handle) = do
        atomicModifyIORef' (probeHandles probe) (\known → (handle : known, ()))
        getPid handle >>= maybe (pure ()) (remember probe)
        forM_ out awaitReadyOn
        when withDescendant $ descendantPid file >>= remember probe
        void (tryPutMVar (probeReady probe) ())
  case ending of
    Returns → scoped (\a b c d → body (a, b, c, d))
    Raises → do
      outcome ← try @Boom (scoped (\a b c d → body (a, b, c, d) >> boom))
      outcome `shouldBe` Left Boom
    TimesOut → do
      outcome ← timeout 1000000 (scoped (\a b c d → body (a, b, c, d) >> holdUntilEnded))
      outcome `shouldBe` Nothing
    Cancelled → do
      outcome ← try @AsyncException (bounded (withCancellationAfter (readMVar (probeReady probe)) (pure ()) (scoped (\a b c d → body (a, b, c, d) >> holdUntilEnded))))
      outcome `shouldBe` Left UserInterrupt
    CancelledStarting → do
      outcome ← try @AsyncException (unownedStart process (\a b c d → body (a, b, c, d) >> (throwIO UserInterrupt ∷ IO ())))
      outcome `shouldBe` Left UserInterrupt
    AcquisitionFails → do
      -- The shape of a start that is not released: the child exists and the step after it fails.
      outcome ← try @Boom (unownedStart process (\a b c d → body (a, b, c, d) >> boom))
      outcome `shouldBe` Left Boom
    ReleaseParked → do
      outcome ← try @AsyncException (bounded (withCancellationAfter (readMVar (probeReady probe)) (pure ()) (scoped (\a b c d → body (a, b, c, d) >> holdUntilEnded))))
      outcome `shouldBe` Left UserInterrupt

awaitReadyOn ∷ Handle → IO ()
awaitReadyOn out = do
  line ← fromMaybe (error "the child did not say it was ready within 30 s") <$> timeout (30 * 1000000) (hGetLine out)
  if "ready" `isInfixOf` line then pure () else awaitReadyOn out

-- | A deliberately unowned start: the child is created and nothing releases it. The controls' only one.
unownedStart ∷ CreateProcess → (Maybe Handle → Maybe Handle → Maybe Handle → ProcessHandleOf → IO a) → IO a
unownedStart process use = do
  (a, b, c, d) ← createProcess process
  use a b c d

type ProcessHandleOf = ProcessHandle

retainsBodyFailure ∷ Either (ExceptionWithContext SomeException) () → Bool
retainsBodyFailure = \case
  Left (ExceptionWithContext context _) →
    any (\(RetainedFailure label text) → "failure of what was being run" `isInfixOf` label && "Boom" `isInfixOf` text) (getExceptionAnnotations context)
  Right () → False

cancellation ∷ Either (ExceptionWithContext SomeException) () → Bool
cancellation = \case
  Left (ExceptionWithContext _ failure) → fromException failure == Just UserInterrupt
  Right () → False

-- | Run a call on the calling thread, cancel it once the child it started has said (through the channel) that it is ready, and
-- answer that child's identifier, which is also recorded for the control's rescue.
cancelledCall ∷ IORef [ProcessID] → IO String → IO a → IO ProcessID
cancelledCall known next call = do
  pidVar ← newEmptyMVar
  let event = next >>= \line → let pid = readPid line in atomicModifyIORef' known (\old → (pid : old, ())) >> putMVar pidVar pid
  outcome ← try @AsyncException (bounded (withCancellationAfter event (pure ()) (void call)))
  outcome `shouldBe` Left UserInterrupt
  readMVar pidVar

readPid ∷ String → ProcessID
readPid line = CPid (read (words line !! 1))

-- | The command whose readiness is told through the channel, whose path is its first argument.
stubbornThroughChannel ∷ String
stubbornThroughChannel = "trap '' TERM; echo \"ready $$\" > \"$1\"; while :; do sleep 1; done"

withTemp ∷ (FilePath → IO a) → IO a
withTemp = withSystemTempDirectory "hetoimasia-subprocess"

foreign import ccall unsafe "getsid" c_getsid ∷ CPid → IO CPid

spec ∷ Spec
spec = describe "the shared subprocess facility (Test.Support.Subprocess)" $ do
  describe "a command run to completion" $ do
    it "answers its status and everything it wrote, with the environment, working directory and input it was given" $
      withTemp $ \directory → do
        let command = (shell "cat; echo \"$GREETING\"; pwd -P >&2; exit 3" []) {env = Just [("GREETING", "hello"), ("PATH", "/usr/bin:/bin")], cwd = Just directory}
        Completed status out err drain ← runToCompletion hangCatcher command "typed\n"
        (status, out, drain) `shouldBe` (ExitFailure 3, "typed\nhello\n", Drained)
        canonical ← canonicalizePath directory
        err `shouldBe` (canonical <> "\n")

    it "starts a child in the root directory with an environment, as the display helpers' fixtures do" $ do
      -- The process library on macOS refuses the directory spelled "/" for a child with an environment and a group of its own
      -- ("chdir: does not exist"); the facility spells the same directory so that it starts.
      (status, out, _) ← runCaptured hangCatcher (proc "pwd" []) {cwd = Just "/", env = Just [("PATH", "/usr/bin:/bin")]} ""
      (status, out) `shouldBe` (ExitSuccess, "/\n")

    it "answers the triple the library call answered" $ do
      (status, out, err) ← runCaptured hangCatcher (shell "echo out; echo err >&2" []) ""
      (status, out, err) `shouldBe` (ExitSuccess, "out\n", "err\n")

    it "does not block a child that writes more than a pipe buffer to both streams before exiting" $ do
      Completed status out err drain ← runToCompletion hangCatcher (shell "head -c 300000 /dev/zero | tr '\\0' x; head -c 300000 /dev/zero | tr '\\0' y >&2" []) ""
      (status, length out, all (== 'x') out, length err, all (== 'y') err, drain) `shouldBe` (ExitSuccess, 300000, True, 300000, True, Drained)

    it "gives a command that reads its input the end of it" $ do
      (status, out, _) ← runCaptured hangCatcher (shell "cat" []) ""
      (status, out) `shouldBe` (ExitSuccess, "")

    it "gives up on a pipe a descendant keeps open after the child exited, keeps what was read, says so, and ends the descendant" $ do
      Completed status out _ drain ← runToCompletionUsing quick {boundDrain = 1000000} noSeams hangCatcher (shell "echo hello; sleep 300 & echo \"background $!\"" []) ""
      status `shouldBe` ExitSuccess
      drain `shouldBe` DrainGivenUp
      lines out `shouldSatisfy` (\ls → take 1 ls == ["hello"] && length ls == 2)
      awaitGone (readPid (last (lines out))) >>= (`shouldBe` True)

    it "fails the captured form when the drain was given up on, saying what was read" $ do
      outcome ← try @SubprocessFailure (runCapturedUsing quick {boundDrain = 1000000} noSeams hangCatcher (shell "echo hello; sleep 300 &" []) "")
      case outcome of
        Left (SubprocessFailure message) → message `shouldContain` "hello"
        Right _ → expectationFailure "a pipe held open past the drain bound was not reported"

    it "fails naming the command and the bound when the run bound expires, and ends a child that ignores SIGTERM" $
      withTemp $ \directory → withChannel directory $ \path next → do
        known ← newIORef []
        (do
            outcome ← try @SubprocessFailure (runToCompletionUsing quick noSeams (Within 1000000) (shell stubbornThroughChannel [path]) "")
            case outcome of
              Left (SubprocessFailure message) → (message `shouldContain` "sh") >> (message `shouldContain` "run bound of 1 s")
              Right _ → expectationFailure "the run bound did not fail the call"
            pid ← readPid <$> next
            atomicModifyIORef' known (\old → (pid : old, ()))
            goneAndReaped pid >>= (`shouldBe` True))
          `finally` (readIORef known >>= rescue)

    it "negative control: the library call leaves a child that ignores SIGTERM running when its bound expires" $
      withTemp $ \directory → withChannel directory $ \path next → do
        known ← newIORef []
        (do
            outcome ← timeout 1000000 (libraryRun (shell stubbornThroughChannel [path]))
            outcome `shouldBe` Nothing
            pid ← readPid <$> next
            atomicModifyIORef' known (\old → (pid : old, ()))
            -- The judgement is made about a child the call left; only then does anything independent touch it.
            goneAndReaped pid >>= (`shouldBe` False))
          `finally` (readIORef known >>= rescue)

    it "leaves a cancelled call's child gone and reaped although it ignores SIGTERM" $
      withTemp $ \directory → withChannel directory $ \path next → do
        known ← newIORef []
        (do
            pid ← cancelledCall known next (runToCompletionUsing quick noSeams hangCatcher (shell stubbornThroughChannel [path]) "")
            goneAndReaped pid >>= (`shouldBe` True))
          `finally` (readIORef known >>= rescue)

    it "negative control: the library call leaves a cancelled call's child that ignores SIGTERM running" $
      withTemp $ \directory → withChannel directory $ \path next → do
        known ← newIORef []
        (do
            pid ← cancelledCall known next (libraryRun (shell stubbornThroughChannel [path]))
            goneAndReaped pid >>= (`shouldBe` False))
          `finally` (readIORef known >>= rescue)

    it "leaves no process when a converted helper that suites call (Sandbox.run) is cancelled" $
      withTemp $ \directory → withChannel directory $ \path next → do
        known ← newIORef []
        environment ← sanitizedEnvironment
        (do
            pid ← cancelledCall known next (run environment directory "sh" ["-c", stubbornThroughChannel, "sh", path])
            goneAndReaped pid >>= (`shouldBe` True))
          `finally` (readIORef known >>= rescue)

    it "negative control: the helper's former library call leaves its cancelled child running" $
      withTemp $ \directory → withChannel directory $ \path next → do
        known ← newIORef []
        environment ← sanitizedEnvironment
        (do
            pid ←
              cancelledCall known next $
                libraryRun ((proc "sh" ["-c", stubbornThroughChannel, "sh", path]) {cwd = Just directory, env = Just environment})
            goneAndReaped pid >>= (`shouldBe` False))
          `finally` (readIORef known >>= rescue)

  describe "a scoped child, whichever way its scope ends" $
    for_ endings $ \(label, ending) → do
      it ("has ended the child and the descendant in its group, and reaped them, when the scope " <> label) $
        withTemp $ \directory → do
          probe ← newProbe
          facilityScope stubbornPair True directory probe ending
          pids ← readIORef (probePids probe)
          pids `shouldSatisfy` (not . null)
          mapM goneAndReaped pids >>= (`shouldBe` map (const True) pids)

      it ("negative control: the library call leaves the child running when the scope " <> label) $
        withTemp $ \directory → do
          probe ← newProbe
          (do
              libraryScope stubbornPair True directory probe ending
              pids ← readIORef (probePids probe)
              pids `shouldSatisfy` (not . null)
              judgement ← and <$> mapM goneAndReaped pids
              judgement `shouldBe` False)
            `finally` rescueProbe probe

  describe "a leader that exits while its descendant ignores SIGTERM" $
    for_ [("on SIGTERM", leaderExitingOnTerm, Raises), ("by itself", leaderExitingNormally, Returns)] $ \(label, script, ending) → do
      it ("leaves no descendant after the call when the leader exits " <> label) $
        withTemp $ \directory → do
          probe ← newProbe
          facilityScope script True directory probe ending
          pids ← readIORef (probePids probe)
          length pids `shouldBe` 2
          mapM goneAndReaped pids >>= (`shouldBe` [True, True])

      it ("negative control: the library call leaves the descendant running when the leader exits " <> label) $
        withTemp $ \directory → do
          probe ← newProbe
          (do
              libraryScope script True directory probe ending
              pids ← readIORef (probePids probe)
              length pids `shouldBe` 2
              -- The descendant is the one that is not the leader: it is judged on its own.
              descendant ← goneAndReaped (last pids)
              descendant `shouldBe` False)
            `finally` rescueProbe probe

  describe "the escalation" $ do
    it "sends SIGTERM and then SIGKILL, both to the group, to a child that ignores SIGTERM" $
      withTemp $ \_ → do
        probe ← newProbe
        sent ← newIORef []
        let seams = noSeams {seamSignalled = \target signal → atomicModifyIORef' sent (\old → (old <> [(target, signal)], ()))}
        void $ withScopedChildUsing quick seams (childSpec hangCatcher (shell stubbornAlone [])) $ \child → remember probe (childPid child) >> awaitReady child
        readIORef sent >>= (`shouldBe` [(ToGroup, sigTERM), (ToGroup, sigKILL)])
        readIORef (probePids probe) >>= mapM goneAndReaped >>= (`shouldBe` [True])

    it "does not send SIGKILL to a child that exits on SIGTERM, within the fixed 2 s grace" $ do
      probe ← newProbe
      sent ← newIORef []
      let seams = noSeams {seamSignalled = \target signal → atomicModifyIORef' sent (\old → (old <> [(target, signal)], ()))}
      outcome ← try @Boom (withScopedChildUsing defaultBounds seams (childSpec hangCatcher (shell obedientAlone [])) (\child → remember probe (childPid child) >> awaitReady child >> boom))
      outcome `shouldBe` Left Boom
      readIORef sent >>= (`shouldBe` [(ToGroup, sigTERM)])
      readIORef (probePids probe) >>= mapM goneAndReaped >>= (`shouldBe` [True])

    it "sends nothing to a child that exited by itself and left no member of its group" $ do
      probe ← newProbe
      sent ← newIORef []
      let seams = noSeams {seamSignalled = \target signal → atomicModifyIORef' sent (\old → (old <> [(target, signal)], ()))}
      void $ withScopedChildUsing quick seams (childSpec hangCatcher (shell "exit 0" [])) $ \child → do
        remember probe (childPid child)
        waitChild child (30 * 1000000) >>= (`shouldBe` Just ExitSuccess)
      readIORef sent >>= (`shouldBe` [])

  describe "a reap or an end of a group that is not confirmed" $ do
    it "fails an otherwise passing call and says the reap was not confirmed, whatever state the child is left in" $ do
      seen ← newIORef Nothing
      let seams = noSeams {seamPoll = \_ → pure Nothing, seamWait = \_ _ → pure Nothing}
          unconfirmed = quick {boundReap = 200000}
      outcome ← try @SubprocessFailure (withScopedChildUsing unconfirmed seams (childSpec hangCatcher (shell obedientAlone [])) (\child → writeIORef seen (Just child) >> awaitReady child))
      case outcome of
        Left (SubprocessFailure message) → message `shouldContain` "not reaped"
        Right () → expectationFailure "an unconfirmed reap passed"
      child ← maybe (expectationFailure "the body never ran" >> ioError (userError "unreachable")) pure =<< readIORef seen
      -- Recorded before the rescue, and by a check that does not reap: the child has exited and is still a zombie.
      observed ← awaitUnreapedExit child (30 * 1000000)
      -- The rescue: reap it, so that the example leaves no process.
      void (waitForProcess (childProcess child)) `finally` pure ()
      observed `shouldBe` Just ExitedUnreaped
      goneAndReaped (childPid child) >>= (`shouldBe` True)

    it "fails an otherwise passing call and says processes of the group remained when their end is not observed" $
      withTemp $ \directory → do
        probe ← newProbe
        let seams = noSeams {seamGroupRemains = \_ → pure True}
            unconfirmed = quick {boundGrace = 50000, boundReap = 300000}
            file = directory </> "descendant"
        outcome ← try @SubprocessFailure (withScopedChildUsing unconfirmed seams (childSpec hangCatcher (shell stubbornPair [file])) (prepare file probe True))
        case outcome of
          Left (SubprocessFailure message) → message `shouldContain` "remained"
          Right () → expectationFailure "a group whose end was not observed passed"
        pids ← readIORef (probePids probe)
        -- The leader was reaped by the facility (a non-reaping look finds it is not even a child any more); the example then ends the
        -- group itself, so it leaves no process.
        case pids of
          leader : _ → do
            void (try (signalProcessGroup sigKILL leader) ∷ IO (Either IOException ()))
            mapM awaitGone pids >>= (`shouldBe` [True, True])
          [] → expectationFailure "the body never ran"

    it "fails an otherwise passing call and says the pipes did not end when a holder outside the group keeps them open" $ do
      -- A holder that left the child's session (and so its process group) keeps the output open after the child is gone and its
      -- group is ended: no group signal reaches it, so the pipes cannot end.
      held ← newIORef []
      (do
          outcome ←
            try @SubprocessFailure $
              withScopedChildUsing quick {boundDrain = 300000} noSeams (childSpec hangCatcher (shell "perl -MPOSIX -e 'POSIX::setsid(); $| = 1; print \"ready $$\\n\"; sleep 300' &\nwhile :; do :; done" [])) $ \child → do
                line ← nextLine child Stdout (30 * 1000000)
                case line of
                  Line text → atomicModifyIORef' held (\old → (readPid text : old, ()))
                  other → expectationFailure ("the holder did not say it was ready: " <> show other)
          case outcome of
            Left (SubprocessFailure message) → message `shouldContain` "pipes did not end"
            Right () → expectationFailure "pipes held open outside the group passed"
          readIORef held >>= mapM goneAndReaped >>= (`shouldBe` [False]))
        `finally` (readIORef held >>= rescue)

    it "never signals the group again once it was observed gone, whatever the identifier is later given to" $ do
      -- The probe answers that the group is gone and then, as if the identifier had been given to an unrelated group, that a member
      -- remains: the release has already seen the group end, so it sends nothing.
      answers ← newIORef [False, True, True, False]
      sent ← newIORef []
      let reuse _ = atomicModifyIORef' answers (\known → case known of next : rest → (rest, next); [] → ([], False))
          seams = noSeams {seamGroupRemains = reuse, seamSignalled = \target signal → atomicModifyIORef' sent (\old → (old <> [(target, signal)], ()))}
      withScopedChildUsing quick seams (childSpec hangCatcher (shell "exit 0" [])) $ \child →
        waitChild child (30 * 1000000) >>= (`shouldBe` Just ExitSuccess)
      readIORef sent >>= (`shouldBe` [])
      -- The first probe consumed the "gone" answer and no later one was asked.
      readIORef answers >>= (`shouldBe` [True, True, False])

    it "keeps a closed or broken diagnostic stream from replacing the body's own failure" $ do
      let seams =
            noSeams
              { seamPoll = \_ → pure Nothing
              , seamWait = \_ _ → pure Nothing
              , seamDiagnostic = \_ → ioError (userError "the diagnostic stream is closed")
              }
      seen ← newIORef Nothing
      outcome ← try @Boom (withScopedChildUsing quick {boundReap = 100000} seams (childSpec hangCatcher (shell obedientAlone [])) (\child → writeIORef seen (Just child) >> awaitReady child >> boom))
      outcome `shouldBe` Left Boom
      readIORef seen >>= mapM_ (\child → awaitUnreapedExit child (30 * 1000000) >> waitForProcess (childProcess child))

    it "keeps the body's failure beside a cancellation that arrives while the cleanup is being reported" $ do
      seen ← newIORef Nothing
      outcome ← parkedRelease defaultParkBounds $ \park →
        let seams = noSeams {seamPoll = \_ → pure Nothing, seamWait = \_ _ → pure Nothing, seamDiagnostic = \_ → park}
         in withScopedChildUsing quick {boundReap = 100000} seams (childSpec hangCatcher (shell obedientAlone [])) (\child → writeIORef seen (Just child) >> awaitReady child >> boom)
      outcome `shouldSatisfy` cancellation
      outcome `shouldSatisfy` retainsBodyFailure
      readIORef seen >>= mapM_ (\child → awaitUnreapedExit child (30 * 1000000) >> waitForProcess (childProcess child))

    it "raises the body's own failure, not the unconfirmed cleanup, when the body failed" $ do
      let seams = noSeams {seamPoll = \_ → pure Nothing, seamWait = \_ _ → pure Nothing}
      seen ← newIORef Nothing
      outcome ← try @Boom (withScopedChildUsing quick {boundReap = 100000} seams (childSpec hangCatcher (shell obedientAlone [])) (\child → writeIORef seen (Just child) >> awaitReady child >> boom))
      outcome `shouldBe` Left Boom
      readIORef seen >>= mapM_ (\child → awaitUnreapedExit child (30 * 1000000) >> waitForProcess (childProcess child))

  describe "the release" $ do
    it "retains the body's failure beside a cancellation delivered into it, and still reaps the child" $
      withTemp $ \directory → do
        probe ← newProbe
        facilityScope stubbornPair True directory probe ReleaseParked
        readIORef (probePids probe) >>= mapM goneAndReaped >>= (`shouldBe` [True, True])

    it "runs the body with the caller's interruptibility restored" $ do
      states ← newEmptyMVar
      void $ withScopedChildUsing quick noSeams (childSpec hangCatcher (shell "exit 0" [])) (\_ → getMaskingState >>= putMVar states)
      readMVar states >>= (`shouldBe` Unmasked)

  describe "the streams" $ do
    for_ streamChoices $ \(streamName, choice) →
      for_ [("standard input", 0 ∷ Int), ("standard output", 1), ("standard error", 2)] $ \(which, index) →
        it ("ends a child on a failing body when " <> which <> " is " <> streamName) $
          withTemp $ \directory → withChannel directory $ \path next → do
            known ← newIORef []
            (do
                chosen ← choice directory index
                let setting = case index of 0 → \c → c {specStdin = chosen}; 1 → \c → c {specStdout = chosen}; _ → \c → c {specStderr = chosen}
                outcome ←
                  try @Boom $
                    withScopedChildUsing quick noSeams (setting (childSpec hangCatcher (shell stubbornThroughChannel [path]))) $ \child → do
                      pid ← readPid <$> next
                      atomicModifyIORef' known (\old → (pid : old, ()))
                      pid `shouldBe` childPid child
                      boom
                outcome `shouldBe` Left Boom
                readIORef known >>= mapM goneAndReaped >>= (`shouldBe` [True]))
              `finally` (readIORef known >>= rescue)

    it "keeps an absent standard input absent: the child finds it closed, and never gets another stream in its place" $ do
      (_, out, _) ← runCapturedAbsent
      out `shouldBe` "closed\n"

    it "gives a child with a standard input of its own an open one" $ do
      Completed _ out _ _ ← runToCompletion hangCatcher (shell "(exec 3<&0) 2>/dev/null && echo open || echo closed" []) ""
      out `shouldBe` "open\n"

  describe "what the body reads of a piped stream" $ do
    it "takes the lines as they arrive, then the unterminated last one, then reports the end" $
      withScopedChild (childSpec hangCatcher (shell "printf 'one\\ntwo'" [])) $ \child → do
        nextLine child Stdout (30 * 1000000) >>= (`shouldBe` Line "one")
        nextLine child Stdout (30 * 1000000) >>= (`shouldBe` Line "two")
        nextLine child Stdout (30 * 1000000) >>= (`shouldBe` EndOfStream)
        nextLine child Stderr (30 * 1000000) >>= (`shouldBe` EndOfStream)

    it "reports a bound that expired while the stream was still open and quiet" $
      withScopedChild (childSpec hangCatcher (shell obedientAlone [])) $ \child → do
        awaitReady child
        nextLine child Stdout 0 >>= (`shouldBe` TimedOut)

    it "answers what was not taken as lines, to the stream's end, and everything it delivered" $
      withScopedChild (childSpec hangCatcher (shell "printf 'a\\nb\\nc\\n'" [])) $ \child → do
        nextLine child Stdout (30 * 1000000) >>= (`shouldBe` Line "a")
        restOfOutput child Stdout (30 * 1000000) >>= (`shouldBe` Just "b\nc\n")
        captured child Stdout >>= (`shouldBe` "a\nb\nc\n")
        outputFailure child Stdout >>= (`shouldBe` Nothing)

    it "has nothing to read of a stream that was not piped" $
      withScopedChild (childSpec hangCatcher (shell "exit 0" [])) {specStdout = Absent} $ \child → do
        nextLine child Stdout (30 * 1000000) >>= (`shouldBe` EndOfStream)
        captured child Stdout >>= (`shouldBe` "")
        restOfOutput child Stdout (30 * 1000000) >>= (`shouldBe` Just "")

  describe "a handle the caller opened" $ do
    it "is closed by the facility when the start fails" $
      withTemp $ \directory → do
        handle ← openFile (directory </> "log") WriteMode
        outcome ← try @IOException (withScopedChild (childSpec hangCatcher (proc "/nonexistent/hetoimasia-command" [])) {specStdout = CallerHandle handle} (\_ → pure ()))
        outcome `shouldSatisfy` either (const True) (const False)
        hIsOpen handle >>= (`shouldBe` False)

    it "is closed by the facility when the call fails after the child exists, before the body is entered" $
      withTemp $ \directory → do
        handle ← openFile (directory </> "log") WriteMode
        entered ← newIORef False
        outcome ←
          try @Boom $
            withScopedChildUsing quick noSeams {seamSpawned = \_ → boom} (childSpec hangCatcher (shell "exit 0" [])) {specStdout = CallerHandle handle} (\_ → writeIORef entered True)
        outcome `shouldBe` Left Boom
        readIORef entered >>= (`shouldBe` False)
        hIsOpen handle >>= (`shouldBe` False)

    it "is closed by the facility when the call is cancelled before the body is entered" $
      withTemp $ \directory → do
        handle ← openFile (directory </> "log") WriteMode
        outcome ←
          try @AsyncException $
            withScopedChildUsing quick noSeams {seamSpawned = \_ → throwIO UserInterrupt} (childSpec hangCatcher (shell "exit 0" [])) {specStdout = CallerHandle handle} (\_ → pure ())
        outcome `shouldBe` Left UserInterrupt
        hIsOpen handle >>= (`shouldBe` False)

    it "closes the caller's handle when a cancellation queued during the acquisition lands as the body is about to begin" $
      withTemp $ \directory → do
        handle ← openFile (directory </> "log") WriteMode
        spawned ← newEmptyMVar
        helperVar ← newEmptyMVar
        caller ← myThreadId
        entered ← newIORef False
        -- The cancellation is sent while the acquisition is masked and the seam does not return until its sender is blocked delivering
        -- it, so it is delivered the moment the mask is lifted, before any of the body has run.
        let seams = noSeams {seamSpawned = \_ → putMVar spawned () >> readMVar helperVar >>= void . awaitBlockedSending}
        outcome ←
          try @AsyncException . bounded $
            withOwnedThread (readMVar spawned >> throwTo caller UserInterrupt) $ \helper _ → do
              putMVar helperVar helper
              withScopedChildUsing quick seams (childSpec hangCatcher (shell "exit 0" [])) {specStdout = CallerHandle handle} (\_ → writeIORef entered True)
        outcome `shouldBe` Left UserInterrupt
        readIORef entered >>= (`shouldBe` False)
        hIsOpen handle >>= (`shouldBe` False)

    it "stays the caller's: open while the body runs, and open after the call, however the body ended" $
      withTemp $ \directory → do
        handle ← openFile (directory </> "log") WriteMode
        during ← newIORef False
        outcome ← try @Boom (withScopedChild (childSpec hangCatcher (shell "echo written" [])) {specStdout = CallerHandle handle} (\child → do
          void (waitChild child (30 * 1000000))
          hIsOpen handle >>= writeIORef during
          boom))
        outcome `shouldBe` Left Boom
        readIORef during >>= (`shouldBe` True)
        hIsOpen handle >>= (`shouldBe` True)
        hClose handle
        readFile (directory </> "log") >>= (`shouldBe` "written\n")

  describe "a child that has exited and has not been reaped" $
    it "is seen exited and not reaped by the body when the reap is left to the release, which reaps it" $ do
      seen ← newIORef Nothing
      withScopedChild (childSpec hangCatcher (shell "exit 0" [])) $ \child → do
        writeIORef seen (Just child)
        awaitUnreapedExit child (30 * 1000000) >>= (`shouldBe` Just ExitedUnreaped)
        childState child >>= (`shouldBe` ExitedUnreaped)
        -- Still a zombie: a null signal answers for it.
        goneAndReaped (childPid child) >>= (`shouldBe` False)
      child ← maybe (expectationFailure "the body never ran" >> ioError (userError "unreachable")) pure =<< readIORef seen
      childState child >>= (`shouldBe` Reaped)
      goneAndReaped (childPid child) >>= (`shouldBe` True)

  describe "where the child is placed" $ do
    it "puts a child in a process group of its own and keeps it in the caller's session" $ do
      ours ← getProcessGroupID
      session ← c_getsid 0
      withScopedChild (childSpec hangCatcher (shell obedientAlone [])) $ \child → do
        awaitReady child
        group ← getProcessGroupIDOf (childPid child)
        childSession ← c_getsid (childPid child)
        group `shouldBe` childPid child
        group `shouldSatisfy` (/= ours)
        childSession `shouldBe` session

    it "keeps a child in the caller's process group when it says so, and signals its identifier only" $
      withTemp $ \directory → do
        ours ← getProcessGroupID
        probe ← newProbe
        sent ← newIORef []
        let seams = noSeams {seamSignalled = \target signal → atomicModifyIORef' sent (\old → (old <> [(target, signal)], ()))}
            file = directory </> "descendant"
        known ← newIORef []
        (do
            withScopedChildUsing quick seams (childSpec hangCatcher (shell stubbornPair [file])) {specPlacement = CallersGroup} $ \child → do
              prepare file probe True child
              getProcessGroupIDOf (childPid child) >>= (`shouldBe` ours)
            pids ← readIORef (probePids probe)
            writeIORef known pids
            readIORef sent >>= (`shouldBe` [(ToProcess, sigTERM), (ToProcess, sigKILL)])
            -- The child is gone; its descendant (the first identifier, the most recent first), which shares the caller's group, was
            -- not signalled, so it is still there.
            mapM goneAndReaped pids >>= (`shouldBe` [False, True]))
          `finally` (readIORef known >>= rescue)

  describe "a call with no bound of its own" $ do
    it "cannot be made without stating a run bound" $ do
      -- The signatures are the contract: a bound is the first argument and there is no default to fall back on.
      let required = (runToCompletion ∷ RunBound → CreateProcess → String → IO Completed, childSpec ∷ RunBound → CreateProcess → ChildSpec)
      (required `seq` (), specBound (childSpec Unbounded (proc "true" []))) `shouldBe` ((), Unbounded)

    for_ [("raises from its body", Raises), ("is cancelled in its body", Cancelled)] $ \(label, ending) →
      it ("still ends a call that states it is unbounded when its body " <> label) $
        withTemp $ \directory → do
          probe ← newProbe
          let file = directory </> "descendant"
              body child = prepare file probe True child
              unbounded = childSpec Unbounded (shell stubbornPair [file])
          case ending of
            Raises → do
              outcome ← try @Boom (withScopedChildUsing quick noSeams unbounded (\child → body child >> boom))
              outcome `shouldBe` Left Boom
            _ → do
              outcome ← try @AsyncException (bounded (withCancellationAfter (readMVar (probeReady probe)) (pure ()) (withScopedChildUsing quick noSeams unbounded (\child → body child >> holdUntilEnded))))
              outcome `shouldBe` Left UserInterrupt
          readIORef (probePids probe) >>= mapM goneAndReaped >>= (`shouldBe` [True, True])

  describe "a test-owner process that is itself ended from outside while its body is parked" $ do
    it "leaves no child that stays in the owner's process group, because the group is ended with it" $ do
      (child, _) ← outerTermination "shares"
      awaitGone child >>= (`shouldBe` True)

    it "negative control: a child in a group of its own survives the owner's group being ended" $ do
      known ← newIORef []
      (do
          (child, _) ← outerTermination "own"
          atomicModifyIORef' known (\old → (child : old, ()))
          goneAndReaped child >>= (`shouldBe` False))
        `finally` (readIORef known >>= \pids → forM_ pids (\pid → void (try (signalProcessGroup sigKILL pid) ∷ IO (Either IOException ()))) >> rescue pids)

  describe "a host that keeps scoped children's scopes open" $ do
    it "keeps a hosted child alive, its process group unended, after the call that ran it answered, and ends and reaps it with the host" $ do
      known ← newIORef []
      (do
          withHost $ \host → do
            pid ← hosted host (childSpec hangCatcher (shell obedientAlone [])) (\child → awaitReady child >> pure (childPid child))
            atomicModifyIORef' known (\old → (pid : old, ()))
            -- The call answered, and the child is still there for the example to look at.
            goneAndReaped pid >>= (`shouldBe` False)
          readIORef known >>= mapM goneAndReaped >>= (`shouldBe` [True]))
        `finally` (readIORef known >>= rescue)

    it "ends every hosted child, in reverse order of their start, when the host's scope fails" $ do
      known ← newIORef []
      (do
          outcome ← try @Boom $ withHost $ \host → do
            forM_ [1 ∷ Int, 2] $ \_ → do
              pid ← hosted host (childSpec hangCatcher (shell obedientAlone [])) (\child → awaitReady child >> pure (childPid child))
              atomicModifyIORef' known (\old → (pid : old, ()))
            boom
          outcome `shouldBe` Left Boom
          pids ← readIORef known
          length pids `shouldBe` 2
          mapM goneAndReaped pids >>= (`shouldBe` [True, True]))
        `finally` (readIORef known >>= rescue)

    it "ends every hosted child when the host's scope is cancelled" $ do
      known ← newIORef []
      ready ← newEmptyMVar
      (do
          outcome ←
            try @AsyncException . bounded $
              withCancellationAfter (readMVar ready) (pure ()) $
                withHost $ \host → do
                  pid ← hosted host (childSpec hangCatcher (shell stubbornAlone [])) (\child → awaitReady child >> pure (childPid child))
                  atomicModifyIORef' known (\old → (pid : old, ()))
                  putMVar ready ()
                  holdUntilEnded
          outcome `shouldBe` Left UserInterrupt
          readIORef known >>= mapM goneAndReaped >>= (`shouldBe` [True]))
        `finally` (readIORef known >>= rescue)

    it "gives the caller a hosted body's own failure, and goes on serving the next child" $ do
      known ← newIORef []
      (do
          withHost $ \host → do
            first ← try @Boom (hosted host (childSpec hangCatcher (shell obedientAlone [])) (\child → atomicModifyIORef' known (\old → (childPid child : old, ())) >> awaitReady child >> boom))
            first `shouldBe` Left Boom
            second ← hosted host (childSpec hangCatcher (shell obedientAlone [])) (\child → atomicModifyIORef' known (\old → (childPid child : old, ())) >> awaitReady child >> pure (7 ∷ Int))
            second `shouldBe` 7
          readIORef known >>= mapM goneAndReaped >>= (`shouldBe` [True, True]))
        `finally` (readIORef known >>= rescue)

    it "fails a hosted call that passes its run bound, naming the command and the bound" $ do
      known ← newIORef []
      (do
          outcome ← try @SubprocessFailure $ withHost $ \host →
            hosted host (childSpec (Within 1000000) (shell obedientAlone [])) (\child → atomicModifyIORef' known (\old → (childPid child : old, ())) >> awaitReady child >> holdUntilEnded)
          case outcome of
            Left (SubprocessFailure message) → (message `shouldContain` "sh") >> (message `shouldContain` "run bound of 1 s")
            Right () → expectationFailure "the run bound did not fail the hosted call"
          readIORef known >>= mapM goneAndReaped >>= (`shouldBe` [True]))
        `finally` (readIORef known >>= rescue)

  describe "its definition" $
    it "polls in one place only, the observation that a process group is gone, and sleeps nowhere else" $ do
      let path = "tools/test-support/src/Test/Support/Subprocess.hs"
      present ← doesFileExist path
      if not present
        then pendingWith "the facility's source is another package's, which a source distribution does not carry"
        else do
          source ← readFile path
          length (filter ("threadDelay 2000" `isInfixOf`) (lines source)) `shouldBe` 1
          source `shouldNotContain` "threadDelay 1"

-- | Start the suite's own binary as a test-owner process (a child of the example, in a group of its own), which starts one child of
-- its own in its own group or in the owner's, then end the owner's process group from outside while the owner is parked. Answers the
-- owner's child and the owner's group.
outerTermination ∷ String → IO (ProcessID, ProcessGroupID)
outerTermination mode = do
  executable ← getExecutablePath
  inherited ← getEnvironment
  let owner = (proc executable []) {env = Just ((ownerVariable, mode) : inherited)}
  withScopedChild (childSpec hangCatcher owner) {specStdin = Piped} $ \ownerChild → do
    line ← nextLine ownerChild Stdout (30 * 1000000)
    child ← case line of
      Line text | ("child" : pid : _) ← words text → pure (CPid (read pid))
      other → expectationFailure ("the owner did not say what its child was: " <> show other) >> pure 0
    -- The owner leads the group it was started in. Ended from outside, it cannot run the facility's release.
    signalProcessGroup sigKILL (childPid ownerChild)
    void (waitChild ownerChild (30 * 1000000))
    pure (child, childPid ownerChild)

-- | The stream choices a call can make, as a function of the temporary directory and which stream (0 input, 1 output, 2 error).
streamChoices ∷ [(String, FilePath → Int → IO Stream)]
streamChoices =
  [ ("piped", \_ _ → pure Piped)
  , ("absent", \_ _ → pure Absent)
  , ("inherited", \_ _ → pure Inherited)
  , ("a handle the caller opened", \directory index → CallerHandle <$> openFile (directory </> ("stream" <> show index)) (if index == 0 then ReadWriteMode else WriteMode))
  ]

-- | A command that says whether its standard input is closed, run with that stream absent.
runCapturedAbsent ∷ IO (ExitCode, String, String)
runCapturedAbsent = do
  result ← newEmptyMVar
  withScopedChild (childSpec hangCatcher (shell "(exec 3<&0) 2>/dev/null && echo open || echo closed" [])) $ \child → do
    status ← waitChild child (30 * 1000000)
    out ← awaitDrain child >> captured child Stdout
    err ← captured child Stderr
    putMVar result (fromMaybe ExitSuccess status, out, err)
  readMVar result

-- | The library call the converted one-shot sites used to make, which the controls compare the facility with.
libraryRun ∷ CreateProcess → IO (ExitCode, String, String)
libraryRun process = readCreateProcessWithExitCode process ""

-- --------------------------------------------------------------------------
-- The test-owner process

-- | The environment variable that makes this very test executable run as a test-owner process (see 'ownerMain').
ownerVariable ∷ String
ownerVariable = "HETOIMASIA_SUBPROCESS_OWNER"

-- | The test-owner process of the outer-termination examples: the suite's own binary, re-executed. It starts one child through the
-- facility, in the caller's process group when its mode says so, says what the child is, and parks until it is ended from outside.
ownerMain ∷ String → IO ()
ownerMain mode = do
  let placement = if mode == "shares" then CallersGroup else OwnGroup
      process = shell obedientAlone []
  withScopedChild (childSpec Unbounded process) {specPlacement = placement} $ \child → do
    awaitReady child
    putStrLn ("child " <> show (childPid child))
    hFlush stdout
    -- Parked until ended from outside; the owner never gets to run the facility's release.
    void getLine
