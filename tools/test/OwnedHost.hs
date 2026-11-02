-- | Hspec coverage for the hosted subprocess (#608, "Test.Support.Subprocess.Host").
--
-- The host is a state machine: six states, five operations, and a table of how a host or a request comes to an end. Every cell of
-- those tables has an example here, named after it (@State × Operation: …@ or @Cause: …@), and every distinct outcome inside a cell
-- has its own. The mapping from cell to example is recorded in @tools/test-support/README.md@.
--
-- These examples are device-free and deterministic, and none of them sleeps to coordinate anything. Every wait is a state of the
-- host (a wait in STM on 'hostState' or 'awaitQueued'), a gate, an MVar or a line a child writes; a run bound is made to pass by the
-- example saying so (the 'hostLimit' seam) and not by a clock; the one example that uses the real clock states a bound of zero,
-- which passes at once. The 10 s of 'bounded' and the 60 s of 'hangCatcher' exist only to keep a stuck example from hanging the run.
-- Every child is an @sh@ command.
--
-- /Judgement./ A child counts as ended only when it is gone and reaped: a zombie still answers the null signal, so only a null
-- signal that fails with "no such process" ('goneAndReaped') says so.
--
-- /Holding a host in a state./ 'Starting' is held at the worker's first step ('hostBeforeServing'); 'Stopping' at the release of a
-- hosted child (the facility's @seamReleasing@); a request is held in the slot by its submitter being held in its cleanup
-- ('hostAbandoning'); a race is held at the point it is about ('hostTaking', the facility's @seamSpawned@, 'hostEntering'). A gate
-- the worker is held at is opened by the host's own opening ('hostOpen'); a gate a submitter is held at is left open by a
-- cancellation of that submitter, so no failing example leaves a thread waiting.
module OwnedHost (spec) where

import Control.Concurrent (ThreadId, myThreadId, throwTo)
import Control.Concurrent.MVar (MVar, newEmptyMVar, readMVar, tryPutMVar)
import Control.Concurrent.STM
  ( TMVar
  , atomically
  , newEmptyTMVarIO
  , putTMVar
  , readTMVar
  , tryPutTMVar
  , tryReadTMVar
  )
import Control.Exception
  ( AsyncException (ThreadKilled, UserInterrupt)
  , Exception (fromException, toException)
  , ExceptionWithContext (ExceptionWithContext)
  , IOException
  , SomeException
  , asyncExceptionFromException
  , asyncExceptionToException
  , catch
  , finally
  , onException
  , throwIO
  , try
  , tryWithContext
  , uninterruptibleMask_
  )
import Control.Exception.Context (getExceptionAnnotations)
import Control.Monad (forM_, unless, void, when)
import Data.IORef (IORef, atomicModifyIORef', modifyIORef', newIORef, readIORef, writeIORef)
import Data.List (isInfixOf)
import Data.Maybe (isJust, isNothing)
import Data.Unique (hashUnique, newUnique)
import System.Exit (ExitCode (ExitFailure, ExitSuccess))
import System.IO (Handle, hClose, hIsClosed, hIsOpen, hPutStr)
import System.IO.Error (isDoesNotExistError)
import System.IO.Temp (withSystemTempDirectory, withSystemTempFile)
import System.Posix.Signals (Signal, nullSignal, sigTERM, signalProcess)
import System.Posix.Types (ProcessID)
import System.Process (CreateProcess, createPipe, getPid, proc, waitForProcess)
import System.Timeout (timeout)
import Test.Hspec (Spec, describe, expectationFailure, it, shouldBe, shouldReturn, shouldSatisfy)
import Test.Support.Bounded (bounded)
import Test.Support.Owned (withOwnedThread)
import Test.Support.Subprocess
  ( Bounds (boundGrace, boundReap)
  , Child
  , ChildSpec (specStdin, specStdout)
  , Line (Line)
  , Output (Stdout)
  , RetainedFailure (RetainedFailure)
  , RunBound (Unbounded, Within)
  , Seams (seamReleasing, seamSignalled, seamSpawned, seamWait)
  , SignalTarget (ToGroup)
  , Stream (CallerHandle)
  , SubprocessFailure (SubprocessFailure)
  , childPid
  , childSpec
  , defaultBounds
  , nextLine
  , noSeams
  )
import Test.Support.Subprocess.Host
  ( Deadline (DeadlineAt, NoDeadline)
  , Host
  , HostFailure (HostEnded, HostStopped)
  , HostSeams (hostAbandoning, hostBeforeServing, hostClosing, hostEntering, hostLimit, hostOpen, hostTaking)
  , HostState (..)
  , Site (AtBody, AtSubmission)
  , awaitHostState
  , awaitQueued
  , hostQueued
  , hostState
  , hosted
  , hostedCaptured
  , noHostSeams
  , recordStop
  , withHost
  , withHostUsing
  )

-- --------------------------------------------------------------------------
-- Support

-- | A failure an example raises, told apart from every other.
data Boom = Boom
  deriving (Eq, Show)

instance Exception Boom

-- | What a hosted request answers: the value, or the failure with the context it was raised with.
type Answer a = Either (ExceptionWithContext SomeException) a

-- | The facility's bounds as the examples run it: its fixed reap and drain, and a grace short enough that a child which ignores
-- SIGTERM does not make an example wait the fixed 2 s.
quick :: Bounds
quick = defaultBounds {boundGrace = 100000}

hangCatcher :: RunBound
hangCatcher = Within (60 * 1000000)

withHostEx :: Seams -> HostSeams -> (Host -> IO a) -> IO a
withHostEx = withHostUsing quick

shell :: String -> [String] -> CreateProcess
shell script arguments = proc "sh" ("-c" : script : "sh" : arguments)

-- | A child that says when it is ready and then waits to be ended. It is one process (the shell replaces itself with @sleep@), so ending
-- its group leaves nothing to wait for. Its arguments, the label and a file, are unused; the label is how an example recognises its
-- command.
readyScript :: String
readyScript = "echo \"ready $$\"; exec sleep 300"

-- | A child that logs its label to a file when it is ended by SIGTERM, which is how the order its group was ended in is read.
loggedScript :: String
loggedScript = "trap 'echo \"$1\" >> \"$2\"; exit 0' TERM; echo \"ready $$\"; while :; do sleep 1; done"

-- | A request for one such child, with the bound given (an example that makes a bound pass states one; the rest are unbounded).
readyChild :: RunBound -> String -> FilePath -> ChildSpec
readyChild bound label logFile = childSpec bound (shell readyScript [label, logFile])

-- | A request for a child that logs when it is ended.
loggedChild :: RunBound -> String -> FilePath -> ChildSpec
loggedChild bound label logFile = childSpec bound (shell loggedScript [label, logFile])

-- | A child that cannot be started.
missingChild :: RunBound -> ChildSpec
missingChild bound = childSpec bound (proc "/nonexistent/hetoimasia-no-such-program" [])

-- | The path a child that logs nothing is given.
nowhere :: FilePath
nowhere = "/dev/null"

-- | Wait for the child to say it is ready, within 30 s, and answer the line.
awaitReadyLine :: Child -> IO String
awaitReadyLine child =
  nextLine child Stdout (30 * 1000000) >>= \case
    Line text | "ready" `isInfixOf` text -> pure text
    Line _ -> awaitReadyLine child
    other -> expectationFailure ("the child did not say it was ready: " <> show other) >> pure ""

awaitReady :: Child -> IO ()
awaitReady = void . awaitReadyLine

-- | A body that learns the child's identifier once it is ready.
pidBody :: Child -> IO ProcessID
pidBody child = awaitReady child >> pure (childPid child)

-- | A request's body that records it ran, then reports its child.
flagged :: IORef Bool -> Child -> IO ProcessID
flagged ran child = writeIORef ran True >> pidBody child

-- | Is the process gone and reaped? A zombie still answers the null signal, so only "no such process" says so.
goneAndReaped :: ProcessID -> IO Bool
goneAndReaped pid =
  (signalProcess nullSignal pid >> pure False)
    `catch` \(failure :: IOException) -> pure (isDoesNotExistError failure || "No such process" `isInfixOf` show failure)

-- --------------------------------------------------------------------------
-- Gates, held bodies and the bound that passes when the example says so

-- | A place a thread is held: it says it has reached it, once, and waits until the gate is opened. Opening is idempotent and does not
-- block, so it can be the host's own opening.
data Gate = Gate (TMVar ()) (MVar ())

newGate :: IO Gate
newGate = Gate <$> newEmptyTMVarIO <*> newEmptyMVar

park :: Gate -> IO ()
park (Gate reached open) = atomically (void (tryPutTMVar reached ())) >> readMVar open

openGate :: Gate -> IO ()
openGate (Gate _ open) = void (tryPutMVar open ())

awaitReached :: Gate -> IO ()
awaitReached (Gate reached _) = bounded (atomically (readTMVar reached))

-- | Hold a submitter, whose command carries the label, in its cleanup. A cancellation that lands in the hold is remembered and the
-- hold is run again: the second run returns at once, so cancelling a held submitter ends it instead of holding it again.
holdSubmitter :: String -> Gate -> IO (String -> IO ())
holdSubmitter label gate = do
  interrupted <- newIORef False
  pure $ \command ->
    when ((" " <> label <> " ") `isInfixOf` command) $ do
      already <- readIORef interrupted
      unless already (park gate `onException` writeIORef interrupted True)

-- | Hold a cleanup at a gate, once: a cancellation that lands in the hold is remembered and the cleanup run again, and the second
-- run does not hold.
parkOnce :: Gate -> IO (IO ())
parkOnce gate = do
  interrupted <- newIORef False
  pure $ do
    already <- readIORef interrupted
    unless already (park gate `onException` writeIORef interrupted True)

-- | A pipe whose write end has more buffered than the pipe holds, so that closing it cannot flush and waits for a reader that is not
-- there. The caller closes the read end.
blockedPipe :: IO (Handle, Handle)
blockedPipe = do
  (reading, writing) <- createPipe
  void (timeout 300000 (hPutStr writing (replicate 1000000 'y')))
  pure (reading, writing)

-- | A request whose body says it is running, with its child, and then waits until it is released. It records when it was cancelled.
data Held = Held
  { heldEntered :: TMVar ProcessID
  , heldRelease :: MVar ()
  , heldCancelled :: IORef Bool
  }

newHeld :: IO Held
newHeld = Held <$> newEmptyTMVarIO <*> newEmptyMVar <*> newIORef False

heldBody :: Held -> Child -> IO ProcessID
heldBody held child = do
  awaitReady child
  atomically (putTMVar (heldEntered held) (childPid child))
  readMVar (heldRelease held) `onException` writeIORef (heldCancelled held) True
  pure (childPid child)

-- | Wait until the held body is running, and answer its child's identifier.
awaitHeld :: Held -> IO ProcessID
awaitHeld held = bounded (atomically (readTMVar (heldEntered held)))

releaseHeld :: Held -> IO ()
releaseHeld held = void (tryPutMVar (heldRelease held) ())

-- | The exception that makes a bound pass. It is an asynchronous one, as the timeout's is.
newtype Tripped = Tripped Int
  deriving (Show)

instance Exception Tripped where
  toException = asyncExceptionToException
  fromException = asyncExceptionFromException

-- | The two places a bound is measured, each made to pass by the example. A request with no bound is never limited.
data Wires = Wires {wireSubmission :: TMVar (), wireBody :: TMVar ()}

newWires :: IO Wires
newWires = Wires <$> newEmptyTMVarIO <*> newEmptyTMVarIO

trip :: TMVar () -> IO ()
trip wire = atomically (void (tryPutTMVar wire ()))

-- | The host's hooks with the bound made to pass by the wires.
withWires :: Wires -> HostSeams
withWires wires = noHostSeams {hostLimit = limitBy wires}

limitBy :: Wires -> Site -> Deadline -> IO a -> IO (Maybe a)
limitBy wires site deadline action = case deadline of
  NoDeadline -> Just <$> action
  DeadlineAt _ -> expiring (case site of AtSubmission -> wireSubmission wires; AtBody -> wireBody wires) action

-- | Run the action until the wire is tripped; 'Nothing' then, as the timeout answers it. The thread that watches the wire is owned.
expiring :: TMVar () -> IO a -> IO (Maybe a)
expiring wire action = do
  me <- myThreadId
  token <- hashUnique <$> newUnique
  (Just <$> withOwnedThread (atomically (readTMVar wire) >> throwTo me (Tripped token)) (\_ _ -> action))
    `catch` \(Tripped seen) -> if seen == token then pure Nothing else throwIO (Tripped seen)

-- --------------------------------------------------------------------------
-- Submitters

-- | A submission on a thread of its own: its thread, so that the example can cancel it, and the answer it ends with.
data Submission a = Submission ThreadId (TMVar (Answer a))

-- | Submit on a thread of the example's scope, which ends it (cancelling it, if it is still waiting) with the scope.
withSubmission :: Host -> ChildSpec -> (Child -> IO a) -> (Submission a -> IO b) -> IO b
withSubmission host request body use = do
  result <- newEmptyTMVarIO
  withOwnedThread (tryWithContext @SomeException (hosted host request body) >>= atomically . putTMVar result) $ \thread _ ->
    use (Submission thread result)

-- | Submit on a thread that waits for the host to exist and outlives its scope, so that the example reads what the owner's end
-- answered it.
withLateSubmission :: TMVar Host -> ChildSpec -> (Child -> IO a) -> (Submission a -> IO b) -> IO b
withLateSubmission hostVar request body use = do
  result <- newEmptyTMVarIO
  withOwnedThread
    ( do
        host <- atomically (readTMVar hostVar)
        tryWithContext @SomeException (hosted host request body) >>= atomically . putTMVar result
    )
    $ \thread _ -> use (Submission thread result)

-- | The answer, within the bound a stuck example is given.
answered :: Submission a -> IO (Answer a)
answered (Submission _ result) = bounded (atomically (readTMVar result))

isAnswered :: Submission a -> IO Bool
isAnswered (Submission _ result) = isJust <$> atomically (tryReadTMVar result)

-- | Cancel the submitter as a cancellation reaches an example.
cancelSubmitter :: Submission a -> IO ()
cancelSubmitter (Submission thread _) = throwTo thread UserInterrupt

-- | The identifier a successful answer holds.
pidOf :: Answer ProcessID -> IO ProcessID
pidOf = \case
  Right pid -> pure pid
  Left (ExceptionWithContext _ failure) -> expectationFailure ("the request failed: " <> show failure) >> pure 0

hostFailure :: Answer a -> Maybe HostFailure
hostFailure = \case
  Left (ExceptionWithContext _ failure) -> fromException failure
  Right _ -> Nothing

isStopped, isEnded, isCancellation :: Answer a -> Bool
isStopped answer = case hostFailure answer of Just (HostStopped _) -> True; _ -> False
isEnded answer = case hostFailure answer of Just (HostEnded _) -> True; _ -> False
isCancellation = \case
  Left (ExceptionWithContext _ failure) -> fromException failure == Just UserInterrupt
  Right _ -> False

-- | The text of the facility's failure the answer is, if it is one.
subprocessFailure :: Answer a -> Maybe String
subprocessFailure = \case
  Left (ExceptionWithContext _ failure) -> (\(SubprocessFailure message) -> message) <$> fromException failure
  Right _ -> Nothing

-- | Is the answer the failure that names the command and the bound?
namesBound :: String -> Answer a -> Bool
namesBound bound answer = case subprocessFailure answer of
  Just message -> "sh" `isInfixOf` message && ("run bound of " <> bound) `isInfixOf` message
  Nothing -> False

-- | Is the answer the failure of starting the child, as the library raised it?
isStartFailure :: Answer a -> Bool
isStartFailure = \case
  Left (ExceptionWithContext _ failure) -> maybe False isDoesNotExistError (fromException failure)
  Right _ -> False

-- | Every failure kept beside the raised one, as its text.
retained :: ExceptionWithContext e -> [String]
retained (ExceptionWithContext context _) = [label <> ": " <> text | RetainedFailure label text <- getExceptionAnnotations context]

-- | A handle a request supplies: the example checks it from the caller's side.
withSupplied :: (Handle -> IO a) -> IO a
withSupplied use = withSystemTempFile "hosted-handle" (\_ handle -> use handle)

-- | A request that supplies the handle as its child's standard input.
supplying :: Handle -> ChildSpec -> ChildSpec
supplying handle request = request {specStdin = CallerHandle handle}

closed :: Handle -> IO Bool
closed = hIsClosed

-- | Every child's identifier an example collected.
type Pids = IORef [ProcessID]

remember :: Pids -> ProcessID -> IO ()
remember pids pid = atomicModifyIORef' pids (\known -> (pid : known, ()))

assertReaped :: Pids -> IO ()
assertReaped pids = do
  known <- readIORef pids
  known `shouldSatisfy` (not . null)
  mapM goneAndReaped known `shouldReturn` map (const True) known

assertAlive :: Pids -> IO ()
assertAlive pids = do
  known <- readIORef pids
  known `shouldSatisfy` (not . null)
  mapM goneAndReaped known `shouldReturn` map (const False) known

-- | The lines a log holds, oldest first.
logged :: FilePath -> IO [String]
logged file = lines <$> readFile file `catch` \(_ :: IOException) -> pure ""

-- | The SIGTERMs the release of the examples' children sent to a group, in order. (A group member that lingers as a zombie past the
-- grace is sent SIGKILL as well, by the facility's own rule; what an example asks is that no child is ended twice.)
terms :: IORef [(Signal, SignalTarget)] -> IO [Signal]
terms sent = filter (== sigTERM) . reverse . map fst . filter ((== ToGroup) . snd) <$> readIORef sent

countSignals :: IO (IORef [(Signal, SignalTarget)], Seams)
countSignals = do
  sent <- newIORef []
  pure (sent, noSeams {seamSignalled = \target signal -> modifyIORef' sent ((signal, target) :)})

-- | An owner's scope that is expected to raise the example's failure, or a cancellation, as itself.
tryBoom :: IO () -> IO (Either Boom ())
tryBoom = try

tryInterrupt :: IO () -> IO (Either AsyncException ())
tryInterrupt = try

tryBoomValue :: IO ProcessID -> IO (Either Boom ProcessID)
tryBoomValue = try

-- | The answer of an owner's scope that is expected to have returned without failing.
expectReturned :: Answer () -> IO ()
expectReturned = \case
  Right () -> pure ()
  Left (ExceptionWithContext _ failure) -> expectationFailure ("the owner's scope raised " <> show failure)

-- | Run the owner's scope on a thread of its own and let the example look at the host while it is 'Stopping' and its worker has not
-- finished. The owner's use first runs the setup, hands the host over and waits to be told to end; the release of the first hosted
-- child it ends is held at a gate, which the example opens once it has looked (and which it is given), so the example sees the host
-- with the stop recorded, the worker still unwinding and the first child not yet ended. The answer is the owner's scope's.
stoppingWindow
  :: HostSeams
  -> Seams
  -> (Host -> IO ())
  -> Maybe Boom
  -> (Host -> ThreadId -> Gate -> IO (Answer ()) -> IO ())
  -> IO (Answer ())
stoppingWindow hooks facility setup ending look = do
  hostVar <- newEmptyTMVarIO
  finish <- newEmptyTMVarIO
  gate <- newGate
  result <- newEmptyTMVarIO
  let owner =
        tryWithContext @SomeException . withHostEx facility {seamReleasing = park gate} hooks $ \host -> do
          setup host
          atomically (putTMVar hostVar host)
          bounded (atomically (readTMVar finish))
          maybe (pure ()) throwIO ending
      awaitOwner = bounded (atomically (readTMVar result))
  withOwnedThread (owner >>= atomically . putTMVar result) $ \ownerThread _ -> do
    host <- bounded (atomically (readTMVar hostVar))
    ( do
        atomically (putTMVar finish ())
        awaitReached gate
        look host ownerThread gate awaitOwner
      )
      `finally` openGate gate
    awaitOwner

-- | The usual setup of a window: one child, hosted and answered.
oneChild :: Host -> IO ()
oneChild host = void (hosted host (readyChild hangCatcher "a" nowhere) pidBody)

-- --------------------------------------------------------------------------
-- The examples

spec :: Spec
spec = describe "the hosted subprocess (Test.Support.Subprocess.Host)" $ do
  startingSpec
  idleSpec
  servingEmptySpec
  servingQueuedSpec
  stoppingSpec
  endedSpec
  causeSpec
  racesSpec
  cleanupSpec
  cancellabilitySpec
  capturedSpec

-- | A host held in 'Starting': the worker waits at its first step until the gate is opened, which the host's own opening does too.
startingHooks :: Wires -> Gate -> HostSeams
startingHooks wires gate = (withWires wires) {hostBeforeServing = park gate, hostOpen = openGate gate}

startingSpec :: Spec
startingSpec = describe "Starting (opened, the worker not yet serving)" $ do
  it "Starting × Submit: a request is accepted into the slot and served as soon as the worker serves" $ do
    gate <- newGate
    wires <- newWires
    pids <- newIORef []
    withHostEx noSeams (startingHooks wires gate) $ \host ->
      withSubmission host (readyChild Unbounded "a" nowhere) pidBody $ \a -> do
        bounded (awaitQueued host True)
        hostState host `shouldReturn` Starting
        isAnswered a `shouldReturn` False
        openGate gate
        answered a >>= pidOf >>= remember pids
        bounded (awaitHostState host (== Idle))
        assertAlive pids
    assertReaped pids

  it "Starting × Submit: a further submitter waits for the slot within its own bound and is answered at that bound" $ do
    gate <- newGate
    wires <- newWires
    ran <- newIORef False
    withSupplied $ \handle ->
      withHostEx noSeams (startingHooks wires gate) $ \host ->
        withSubmission host (readyChild Unbounded "a" nowhere) pidBody $ \a -> do
          bounded (awaitQueued host True)
          withSubmission host (supplying handle (readyChild (Within 5000000) "b" nowhere)) (flagged ran) $ \b -> do
            -- The slot is full and the bound has not passed: the submitter waits.
            isAnswered b `shouldReturn` False
            trip (wireSubmission wires)
            answered b >>= (`shouldSatisfy` namesBound "5 s")
            closed handle `shouldReturn` True
            readIORef ran `shouldReturn` False
          -- The request that held the slot is still there and is served when the worker serves.
          hostQueued host `shouldReturn` True
          openGate gate
          answered a >>= void . pidOf

  it "Starting × Submit: a further submitter waiting for the slot is answered 'host stopped' when the host stops, not at its bound" $ do
    gate <- newGate
    wires <- newWires
    ranA <- newIORef False
    ranB <- newIORef False
    withSupplied $ \handleA -> withSupplied $ \handleB ->
      withHostEx noSeams (startingHooks wires gate) $ \host ->
        withSubmission host (supplying handleA (readyChild Unbounded "a" nowhere)) (flagged ranA) $ \a -> do
          bounded (awaitQueued host True)
          withSubmission host (supplying handleB (readyChild (Within 5000000) "b" nowhere)) (flagged ranB) $ \b -> do
            recordStop host
            -- The wire is not tripped: the bound never passed. The stop answered the submitter.
            answered b >>= (`shouldSatisfy` isStopped)
            answered a >>= (`shouldSatisfy` isStopped)
            mapM closed [handleA, handleB] `shouldReturn` [True, True]
            mapM readIORef [ranA, ranB] `shouldReturn` [False, False]
            hostQueued host `shouldReturn` False

  it "Starting × Submit: a submitter waiting for the slot is answered 'host ended' when the worker ends by itself, and the scope raises that worker's failure once" $ do
    gate <- newGate
    wires <- newWires
    ran <- newIORef False
    outcome <- tryBoom $
      withSupplied $ \handle ->
        withHostEx noSeams ((startingHooks wires gate) {hostBeforeServing = park gate >> throwIO Boom}) $ \host ->
          withSubmission host (supplying handle (readyChild Unbounded "a" nowhere)) (flagged ran) $ \a -> do
            bounded (awaitQueued host True)
            openGate gate
            answered a >>= (`shouldSatisfy` isEnded)
            bounded (awaitHostState host (== Ended))
            closed handle `shouldReturn` True
            readIORef ran `shouldReturn` False
    outcome `shouldBe` Left Boom

  it "Starting × Bound passes: the queued request is abandoned, its submitter fails naming the command and the bound, it is never started and its handles are closed" $ do
    gate <- newGate
    wires <- newWires
    ran <- newIORef False
    withSupplied $ \handle ->
      withHostEx noSeams (startingHooks wires gate) $ \host ->
        withSubmission host (supplying handle (readyChild (Within 5000000) "a" nowhere)) (flagged ran) $ \a -> do
          bounded (awaitQueued host True)
          trip (wireSubmission wires)
          answered a >>= (`shouldSatisfy` namesBound "5 s")
          closed handle `shouldReturn` True
          readIORef ran `shouldReturn` False
          -- The slot is free for the next submitter, and nothing is served when the worker serves.
          hostQueued host `shouldReturn` False
          openGate gate
          bounded (awaitHostState host (== Idle))
          readIORef ran `shouldReturn` False

  it "Starting × Bound passes: a bound of zero passes at once on the real clock, naming the command and the bound, and starts nothing" $ do
    ran <- newIORef False
    withSupplied $ \handle ->
      withHost $ \host ->
        withSubmission host (supplying handle (readyChild (Within 0) "a" nowhere)) (flagged ran) $ \a -> do
          answered a >>= (`shouldSatisfy` namesBound "0 s")
          closed handle `shouldReturn` True
          readIORef ran `shouldReturn` False

  it "Starting × Submitter cancelled: the submitter sees its own cancellation unchanged, never the bound; the request is never started and its handles are closed" $ do
    gate <- newGate
    wires <- newWires
    ran <- newIORef False
    withSupplied $ \handle ->
      withHostEx noSeams (startingHooks wires gate) $ \host ->
        withSubmission host (supplying handle (readyChild (Within 5000000) "a" nowhere)) (flagged ran) $ \a -> do
          bounded (awaitQueued host True)
          cancelSubmitter a
          answer <- answered a
          answer `shouldSatisfy` isCancellation
          answer `shouldSatisfy` (isNothing . subprocessFailure)
          closed handle `shouldReturn` True
          readIORef ran `shouldReturn` False
          hostQueued host `shouldReturn` False

  it "Starting × Stop: nothing is served; a queued request is answered 'host stopped', never started, its handles closed; the scope returns once the worker has finished" $ do
    gate <- newGate
    wires <- newWires
    ran <- newIORef False
    hostVar <- newEmptyTMVarIO
    withSupplied $ \handle ->
      withLateSubmission hostVar (supplying handle (readyChild Unbounded "a" nowhere)) (flagged ran) $ \a -> do
        withHostEx noSeams (startingHooks wires gate) $ \host -> do
          atomically (putTMVar hostVar host)
          bounded (awaitQueued host True)
        answered a >>= (`shouldSatisfy` isStopped)
        closed handle `shouldReturn` True
        readIORef ran `shouldReturn` False

  it "Starting × Owner fails: as the stop, then the owner's failure is raised as itself" $ do
    gate <- newGate
    wires <- newWires
    ran <- newIORef False
    hostVar <- newEmptyTMVarIO
    withSupplied $ \handle ->
      withLateSubmission hostVar (supplying handle (readyChild Unbounded "a" nowhere)) (flagged ran) $ \a -> do
        outcome <- tryBoom $
          withHostEx noSeams (startingHooks wires gate) $ \host -> do
            atomically (putTMVar hostVar host)
            bounded (awaitQueued host True)
            throwIO Boom
        outcome `shouldBe` Left Boom
        answered a >>= (`shouldSatisfy` isStopped)
        closed handle `shouldReturn` True
        readIORef ran `shouldReturn` False

  it "Starting × Owner is cancelled: as the stop, then the owner's cancellation is raised as itself" $ do
    gate <- newGate
    wires <- newWires
    outcome <- tryInterrupt $
      withHostEx noSeams (startingHooks wires gate) $ \host -> do
        withSubmission host (readyChild Unbounded "a" nowhere) pidBody $ \_ -> bounded (awaitQueued host True)
        throwIO UserInterrupt
    outcome `shouldBe` Left UserInterrupt

  it "Starting × The worker ends by itself: the host becomes Ended, a queued request is answered 'host ended', never started and its handles closed; a cancelled worker is not raised by the scope" $ do
    gate <- newGate
    wires <- newWires
    ran <- newIORef False
    withSupplied $ \handle ->
      withHostEx noSeams ((startingHooks wires gate) {hostBeforeServing = park gate >> throwIO ThreadKilled}) $ \host ->
        withSubmission host (supplying handle (readyChild Unbounded "a" nowhere)) (flagged ran) $ \a -> do
          bounded (awaitQueued host True)
          openGate gate
          answered a >>= (`shouldSatisfy` isEnded)
          closed handle `shouldReturn` True
          readIORef ran `shouldReturn` False
          bounded (awaitHostState host (== Ended))

idleSpec :: Spec
idleSpec = describe "Idle (serving, nothing held)" $ do
  it "Idle × Submit: a request is accepted and served at once, and its child stays hosted" $ do
    pids <- newIORef []
    withHost $ \host -> do
      bounded (awaitHostState host (== Idle))
      hosted host (readyChild hangCatcher "a" nowhere) pidBody >>= remember pids
      hostState host `shouldReturn` Idle
      assertAlive pids
    assertReaped pids

  it "Idle × Bound passes or the submitter is cancelled: not applicable, because nothing is waiting in Idle; the host is Idle only once a request was answered" $ do
    held <- newHeld
    withHost $ \host ->
      withSubmission host (readyChild Unbounded "a" nowhere) (heldBody held) $ \a -> do
        _ <- awaitHeld held
        -- While a request waits for its answer the host is not Idle.
        hostState host `shouldReturn` ServingEmpty
        isAnswered a `shouldReturn` False
        releaseHeld held
        answered a >>= void . pidOf
        bounded (awaitHostState host (== Idle))
        hostQueued host `shouldReturn` False

  it "Idle × Stop: the worker ends, every child is ended in reverse order of their start, and the scope returns after every reap is confirmed" $
    withSystemTempDirectory "hosted-order" $ \directory -> do
      let order = directory <> "/order"
      pids <- newIORef []
      withHost $ \host ->
        forM_ ["first", "second", "third"] $ \label ->
          hosted host (loggedChild hangCatcher label order) pidBody >>= remember pids
      logged order `shouldReturn` ["third", "second", "first"]
      assertReaped pids

  it "Idle × Owner fails: the same, then the owner's failure is raised as itself" $
    withSystemTempDirectory "hosted-order" $ \directory -> do
      let order = directory <> "/order"
      pids <- newIORef []
      outcome <- tryBoom $
        withHost $ \host -> do
          forM_ ["first", "second"] $ \label -> hosted host (loggedChild hangCatcher label order) pidBody >>= remember pids
          throwIO Boom
      outcome `shouldBe` Left Boom
      logged order `shouldReturn` ["second", "first"]
      assertReaped pids

  it "Idle × The worker ends by itself: the host becomes Ended with its children already reaped, and a later submission is refused" $ do
    workerVar <- newEmptyTMVarIO
    pids <- newIORef []
    withHostEx noSeams noHostSeams {hostBeforeServing = myThreadId >>= atomically . putTMVar workerVar} $ \host -> do
      hosted host (readyChild hangCatcher "a" nowhere) pidBody >>= remember pids
      worker <- bounded (atomically (readTMVar workerVar))
      throwTo worker ThreadKilled
      bounded (awaitHostState host (== Ended))
      -- Ended is announced after the worker's scopes unwound.
      assertReaped pids
      outcome <- try @HostFailure (hosted host (readyChild hangCatcher "b" nowhere) pidBody)
      outcome `shouldSatisfy` either (\case HostEnded _ -> True; _ -> False) (const False)

  it "Idle × The worker ends by itself: a failure that is not a cancellation is raised by the owner's scope, and kept beside the owner's own failure" $ do
    ownFailure <- tryBoom $ withHostEx noSeams noHostSeams {hostBeforeServing = throwIO Boom} $ \host ->
      bounded (awaitHostState host (== Ended))
    ownFailure `shouldBe` Left Boom
    both <- tryWithContext @SomeException $
      withHostEx noSeams noHostSeams {hostBeforeServing = throwIO Boom} $ \host -> do
        bounded (awaitHostState host (== Ended))
        throwIO UserInterrupt
    case both of
      Left failure@(ExceptionWithContext _ cause) -> do
        fromException cause `shouldBe` Just UserInterrupt
        retained failure `shouldSatisfy` any (\text -> "the host's worker failed" `isInfixOf` text && "Boom" `isInfixOf` text)
      Right () -> expectationFailure "the owner's cancellation was not raised"

servingEmptySpec :: Spec
servingEmptySpec = describe "Serving a request, slot empty (child starting, or body running)" $ do
  it "Serving, slot empty × Submit: a request is accepted into the slot without blocking and served after the current one" $ do
    held <- newHeld
    order <- newIORef ([] :: [String])
    withHost $ \host ->
      withSubmission host (readyChild Unbounded "a" nowhere) (\child -> heldBody held child <* modifyIORef' order ("a finished" :)) $ \a -> do
        _ <- awaitHeld held
        withSubmission host (readyChild Unbounded "b" nowhere) (\child -> modifyIORef' order ("b started" :) >> pidBody child) $ \b -> do
          bounded (awaitQueued host True)
          hostState host `shouldReturn` ServingQueued
          isAnswered b `shouldReturn` False
          releaseHeld held
          answered a >>= void . pidOf
          answered b >>= void . pidOf
    reverse <$> readIORef order `shouldReturn` ["a finished", "b started"]

  it "Serving, slot empty × Bound passes: the running body is cut at its bound, its submitter fails naming the command and the bound, the child stays hosted and the host goes on serving" $ do
    held <- newHeld
    wires <- newWires
    pids <- newIORef []
    withHostEx noSeams (withWires wires) $ \host -> do
      withSubmission host (readyChild (Within 5000000) "a" nowhere) (heldBody held) $ \a -> do
        pid <- awaitHeld held
        remember pids pid
        trip (wireBody wires)
        answered a >>= (`shouldSatisfy` namesBound "5 s")
        readIORef (heldCancelled held) `shouldReturn` True
        goneAndReaped pid `shouldReturn` False
      hosted host (readyChild Unbounded "b" nowhere) pidBody >>= remember pids
      hostState host `shouldReturn` Idle
    assertReaped pids

  it "Serving, slot empty × The running request's submitter is cancelled: it sees its own cancellation, never the bound; the body is not cancelled by this, the child stays hosted and the host goes on serving" $ do
    held <- newHeld
    pids <- newIORef []
    withHost $ \host -> do
      withSubmission host (readyChild (Within 60000000) "a" nowhere) (heldBody held) $ \a -> do
        pid <- awaitHeld held
        remember pids pid
        cancelSubmitter a
        answer <- answered a
        answer `shouldSatisfy` isCancellation
        answer `shouldSatisfy` (isNothing . subprocessFailure)
        -- The body was not cancelled by it: it runs until it is released.
        readIORef (heldCancelled held) `shouldReturn` False
        hostState host `shouldReturn` ServingEmpty
        releaseHeld held
        bounded (awaitHostState host (== Idle))
        goneAndReaped pid `shouldReturn` False
      hosted host (readyChild Unbounded "b" nowhere) pidBody >>= remember pids
    assertReaped pids

  it "Serving, slot empty × Stop: the running body is cancelled, not waited for; its submitter is answered 'host stopped'; the child is ended and reaped; the scope returns after every reap is confirmed" $ do
    held <- newHeld
    pids <- newIORef []
    hostVar <- newEmptyTMVarIO
    withLateSubmission hostVar (readyChild Unbounded "a" nowhere) (heldBody held) $ \a -> do
      withHost $ \host -> do
        atomically (putTMVar hostVar host)
        awaitHeld held >>= remember pids
      -- The scope has returned with the body never released.
      answered a >>= (`shouldSatisfy` isStopped)
      readIORef (heldCancelled held) `shouldReturn` True
      assertReaped pids

  it "Serving, slot empty × Owner fails: the same, then the owner's failure is raised as itself" $ do
    held <- newHeld
    pids <- newIORef []
    hostVar <- newEmptyTMVarIO
    withLateSubmission hostVar (readyChild Unbounded "a" nowhere) (heldBody held) $ \a -> do
      outcome <- tryBoom $
        withHost $ \host -> do
          atomically (putTMVar hostVar host)
          awaitHeld held >>= remember pids
          throwIO Boom
      outcome `shouldBe` Left Boom
      answered a >>= (`shouldSatisfy` isStopped)
      assertReaped pids

  it "Serving, slot empty × Owner is cancelled: the same, then the owner's cancellation is raised as itself" $ do
    held <- newHeld
    pids <- newIORef []
    outcome <- tryInterrupt $
      withHost $ \host ->
        withSubmission host (readyChild Unbounded "a" nowhere) (heldBody held) $ \_ -> do
          awaitHeld held >>= remember pids
          throwIO UserInterrupt
    outcome `shouldBe` Left UserInterrupt
    assertReaped pids

  it "Serving, slot empty × The worker ends by itself: the running submitter is answered 'host ended before it answered' and the host is Ended with its child already reaped" $ do
    held <- newHeld
    workerVar <- newEmptyTMVarIO
    pids <- newIORef []
    withHostEx noSeams noHostSeams {hostBeforeServing = myThreadId >>= atomically . putTMVar workerVar} $ \host ->
      withSubmission host (readyChild Unbounded "a" nowhere) (heldBody held) $ \a -> do
        awaitHeld held >>= remember pids
        worker <- bounded (atomically (readTMVar workerVar))
        throwTo worker ThreadKilled
        answered a >>= (`shouldSatisfy` isEnded)
        bounded (awaitHostState host (== Ended))
        assertReaped pids

servingQueuedSpec :: Spec
servingQueuedSpec = describe "Serving a request, one queued" $ do
  -- A running request (held) and a queued one (labelled "b"), both unbounded; the example then acts on the host.
  let withBoth wires use = do
        held <- newHeld
        withHostEx noSeams (withWires wires) $ \host ->
          withSubmission host (readyChild Unbounded "a" nowhere) (heldBody held) $ \a -> do
            _ <- awaitHeld held
            use host held a

  it "Serving, one queued × Submit: a further submitter waits for the slot within its own bound and is answered at it" $ do
    wires <- newWires
    ran <- newIORef False
    withSupplied $ \handle -> withBoth wires $ \host _ _ ->
      withSubmission host (readyChild Unbounded "b" nowhere) pidBody $ \_ -> do
        bounded (awaitQueued host True)
        withSubmission host (supplying handle (readyChild (Within 5000000) "c" nowhere)) (flagged ran) $ \c -> do
          isAnswered c `shouldReturn` False
          trip (wireSubmission wires)
          answered c >>= (`shouldSatisfy` namesBound "5 s")
          closed handle `shouldReturn` True
          readIORef ran `shouldReturn` False

  it "Serving, one queued × Submit: a further submitter waiting for the slot is woken and answered 'host stopped' when the host stops, not at its bound" $ do
    wires <- newWires
    ran <- newIORef False
    withSupplied $ \handle -> withBoth wires $ \host _ _ ->
      withSubmission host (readyChild Unbounded "b" nowhere) pidBody $ \_ -> do
        bounded (awaitQueued host True)
        withSubmission host (supplying handle (readyChild (Within 5000000) "c" nowhere)) (flagged ran) $ \c -> do
          recordStop host
          answered c >>= (`shouldSatisfy` isStopped)
          closed handle `shouldReturn` True
          readIORef ran `shouldReturn` False

  it "Serving, one queued × Submit: a further submitter waiting for the slot is woken and answered 'host ended' when the worker ends" $ do
    held <- newHeld
    workerVar <- newEmptyTMVarIO
    ran <- newIORef False
    withSupplied $ \handle ->
      withHostEx noSeams noHostSeams {hostBeforeServing = myThreadId >>= atomically . putTMVar workerVar} $ \host ->
        withSubmission host (readyChild Unbounded "a" nowhere) (heldBody held) $ \_ -> do
          _ <- awaitHeld held
          withSubmission host (readyChild Unbounded "b" nowhere) pidBody $ \_ -> do
            bounded (awaitQueued host True)
            withSubmission host (supplying handle (readyChild Unbounded "c" nowhere)) (flagged ran) $ \c -> do
              worker <- bounded (atomically (readTMVar workerVar))
              throwTo worker ThreadKilled
              answered c >>= (`shouldSatisfy` isEnded)
              closed handle `shouldReturn` True
              readIORef ran `shouldReturn` False

  it "Serving, one queued × Bound passes, for the queued request: it is abandoned and never started, its submitter fails at its bound, its handles are closed and the slot is free for the next submitter" $ do
    wires <- newWires
    ran <- newIORef False
    withSupplied $ \handle -> withBoth wires $ \host held a ->
      withSubmission host (supplying handle (readyChild (Within 5000000) "b" nowhere)) (flagged ran) $ \b -> do
        bounded (awaitQueued host True)
        trip (wireSubmission wires)
        answered b >>= (`shouldSatisfy` namesBound "5 s")
        closed handle `shouldReturn` True
        readIORef ran `shouldReturn` False
        hostQueued host `shouldReturn` False
        -- The running request is untouched, and the next submitter takes the slot.
        isAnswered a `shouldReturn` False
        withSubmission host (readyChild Unbounded "c" nowhere) pidBody $ \c -> do
          bounded (awaitQueued host True)
          releaseHeld held
          answered a >>= void . pidOf
          answered c >>= void . pidOf

  it "Serving, one queued × Submitter cancelled, for the queued request: it sees its own cancellation, is never started, its handles are closed and the slot is free" $ do
    wires <- newWires
    ran <- newIORef False
    withSupplied $ \handle -> withBoth wires $ \host _ _ ->
      withSubmission host (supplying handle (readyChild (Within 5000000) "b" nowhere)) (flagged ran) $ \b -> do
        bounded (awaitQueued host True)
        cancelSubmitter b
        answered b >>= (`shouldSatisfy` isCancellation)
        closed handle `shouldReturn` True
        readIORef ran `shouldReturn` False
        hostQueued host `shouldReturn` False

  it "Serving, one queued × Bound passes, for the running request: it is cut at its bound as in the row above, and the queued request is then served" $ do
    held <- newHeld
    wires <- newWires
    withHostEx noSeams (withWires wires) $ \host ->
      withSubmission host (readyChild (Within 5000000) "a" nowhere) (heldBody held) $ \a -> do
        _ <- awaitHeld held
        withSubmission host (readyChild Unbounded "b" nowhere) pidBody $ \b -> do
          bounded (awaitQueued host True)
          trip (wireBody wires)
          answered a >>= (`shouldSatisfy` namesBound "5 s")
          answered b >>= void . pidOf

  it "Serving, one queued × Stop: the running body is cancelled, the queued request is never started, answered 'host stopped' with its handles closed, though the slot is full" $ do
    held <- newHeld
    firstHost <- newEmptyTMVarIO
    queuedHost <- newEmptyTMVarIO
    ranB <- newIORef False
    pids <- newIORef []
    withSupplied $ \handle ->
      withLateSubmission firstHost (readyChild Unbounded "a" nowhere) (heldBody held) $ \a ->
        withLateSubmission queuedHost (supplying handle (readyChild Unbounded "b" nowhere)) (flagged ranB) $ \b -> do
          withHost $ \host -> do
            atomically (putTMVar firstHost host)
            awaitHeld held >>= remember pids
            atomically (putTMVar queuedHost host)
            bounded (awaitQueued host True)
          answered a >>= (`shouldSatisfy` isStopped)
          answered b >>= (`shouldSatisfy` isStopped)
          readIORef (heldCancelled held) `shouldReturn` True
          closed handle `shouldReturn` True
          readIORef ranB `shouldReturn` False
          assertReaped pids

  it "Serving, one queued × Owner fails: the same, then the owner's failure is raised as itself" $ do
    held <- newHeld
    wires <- newWires
    ranB <- newIORef False
    pids <- newIORef []
    outcome <- tryBoom $
      withHostEx noSeams (withWires wires) $ \host ->
        withSubmission host (readyChild Unbounded "a" nowhere) (heldBody held) $ \_ -> do
          awaitHeld held >>= remember pids
          withSubmission host (readyChild Unbounded "b" nowhere) (flagged ranB) $ \_ -> do
            bounded (awaitQueued host True)
            throwIO Boom
    outcome `shouldBe` Left Boom
    readIORef ranB `shouldReturn` False
    assertReaped pids

  it "Serving, one queued × The worker ends by itself: both submitters are answered 'host ended', the queued request is never started and its handles are closed" $ do
    held <- newHeld
    workerVar <- newEmptyTMVarIO
    ranB <- newIORef False
    withSupplied $ \handle ->
      withHostEx noSeams noHostSeams {hostBeforeServing = myThreadId >>= atomically . putTMVar workerVar} $ \host ->
        withSubmission host (readyChild Unbounded "a" nowhere) (heldBody held) $ \a -> do
          _ <- awaitHeld held
          withSubmission host (supplying handle (readyChild Unbounded "b" nowhere)) (flagged ranB) $ \b -> do
            bounded (awaitQueued host True)
            worker <- bounded (atomically (readTMVar workerVar))
            throwTo worker ThreadKilled
            answered a >>= (`shouldSatisfy` isEnded)
            answered b >>= (`shouldSatisfy` isEnded)
            closed handle `shouldReturn` True
            readIORef ranB `shouldReturn` False

stoppingSpec :: Spec
stoppingSpec = describe "Stopping (the stop is recorded, the worker not finished)" $ do
  it "Stopping × Submit: refused at once, whatever the slot holds (an empty slot)" $ do
    ran <- newIORef False
    outcome <- stoppingWindow noHostSeams noSeams oneChild Nothing $ \host _ _ _ -> do
      hostState host `shouldReturn` Stopping
      hostQueued host `shouldReturn` False
      withSupplied $ \handle ->
        withSubmission host (supplying handle (readyChild Unbounded "z" nowhere)) (flagged ran) $ \z -> do
          answered z >>= (`shouldSatisfy` isStopped)
          closed handle `shouldReturn` True
    expectReturned outcome
    readIORef ran `shouldReturn` False

  it "Stopping × Submit: refused at once, whatever the slot holds (a full slot): the refused submitter does not wait for the slot" $ do
    held <- newHeld
    holding <- newGate
    firstHost <- newEmptyTMVarIO
    queuedHost <- newEmptyTMVarIO
    ran <- newIORef False
    hold <- holdSubmitter "q" holding
    let hooks = noHostSeams {hostAbandoning = hold}
        -- The request that runs is submitted first, the one that queues behind it second, so the order is not a race.
        setup host = do
          atomically (putTMVar firstHost host)
          void (awaitHeld held)
          atomically (putTMVar queuedHost host)
          bounded (awaitQueued host True)
    outcome <-
      withLateSubmission firstHost (readyChild Unbounded "a" nowhere) (heldBody held) $ \_ ->
        withLateSubmission queuedHost (readyChild Unbounded "q" nowhere) pidBody $ \_ ->
          stoppingWindow hooks noSeams setup Nothing $ \host _ _ _ -> do
            -- The queued request's submitter is held before it withdraws, so the slot is full while the host is stopping.
            awaitReached holding
            hostState host `shouldReturn` Stopping
            hostQueued host `shouldReturn` True
            withSubmission host (readyChild Unbounded "z" nowhere) (flagged ran) $ \z ->
              answered z >>= (`shouldSatisfy` isStopped)
            hostQueued host `shouldReturn` True
            openGate holding
    expectReturned outcome
    readIORef ran `shouldReturn` False

  it "Stopping × Bound passes or the submitter is cancelled: a submitter already waiting is answered 'host stopped' at once, not at its bound" $ do
    held <- newHeld
    wires <- newWires
    firstHost <- newEmptyTMVarIO
    queuedHost <- newEmptyTMVarIO
    waitingHost <- newEmptyTMVarIO
    ran <- newIORef False
    withSupplied $ \handle -> do
      -- A runs, B queues behind it, W then waits for the slot: submitted in that order, each once the one before is in place.
      let setup host = do
            atomically (putTMVar firstHost host)
            void (awaitHeld held)
            atomically (putTMVar queuedHost host)
            bounded (awaitQueued host True)
            atomically (putTMVar waitingHost host)
      outcome <-
        withLateSubmission firstHost (readyChild Unbounded "a" nowhere) (heldBody held) $ \_ ->
          withLateSubmission queuedHost (readyChild Unbounded "b" nowhere) pidBody $ \_ ->
            withLateSubmission waitingHost (supplying handle (readyChild (Within 5000000) "w" nowhere)) (flagged ran) $ \w ->
              stoppingWindow (withWires wires) noSeams setup Nothing $ \host _ _ _ -> do
                hostState host `shouldReturn` Stopping
                -- The submitter waiting for the slot was answered by the stop: its wire was never tripped.
                answered w >>= (`shouldSatisfy` isStopped)
                closed handle `shouldReturn` True
      expectReturned outcome
      readIORef ran `shouldReturn` False

  it "Stopping × Stop: idempotent; nothing further happens, so no child is ended a second time and no failure is raised a second time" $ do
    (sent, facility) <- countSignals
    outcome <- stoppingWindow noHostSeams facility oneChild Nothing $ \host _ _ _ -> do
      recordStop host
      recordStop host
      hostState host `shouldReturn` Stopping
    expectReturned outcome
    -- One child, ended once: a single SIGTERM to its group.
    terms sent `shouldReturn` [sigTERM]

  it "Stopping × Owner fails: the cleanup completes with every reap confirmed; a second cancellation arriving during it is remembered, the cleanup finished, the cancellation raised after, with the owner's failure retained" $ do
    pids <- newIORef []
    outcome <- stoppingWindow noHostSeams noSeams (\host -> hosted host (readyChild hangCatcher "a" nowhere) pidBody >>= remember pids) (Just Boom) $
      \_ ownerThread gate awaitOwner -> do
        -- The owner is in its release, which cannot be interrupted: a cancellation sent now waits for the release to end.
        withOwnedThread (throwTo ownerThread UserInterrupt) $ \_ _ -> do
          openGate gate
          void awaitOwner
    case outcome of
      Left failure@(ExceptionWithContext _ cause) -> do
        fromException cause `shouldBe` Just UserInterrupt
        retained failure `shouldSatisfy` any ("Boom" `isInfixOf`)
      Right () -> expectationFailure "the second cancellation was not raised"
    assertReaped pids

  it "Stopping × The worker ends by itself: the host becomes Ended once the worker has finished, and the scope returns once every reap is confirmed" $ do
    pids <- newIORef []
    outcome <- stoppingWindow noHostSeams noSeams (\host -> hosted host (readyChild hangCatcher "a" nowhere) pidBody >>= remember pids) Nothing $
      \host _ gate _ -> do
        hostState host `shouldReturn` Stopping
        assertAlive pids
        openGate gate
        bounded (awaitHostState host (== Ended))
    expectReturned outcome
    assertReaped pids

  it "Stopping × The worker ends by itself: a cleanup that was not confirmed is raised once, after every other child was ended, and kept beside the owner's failure" $ do
    -- The reap of the first child is not observed (an injected wait that answers nothing); its group is killed all the same.
    target <- newIORef Nothing
    handles <- newIORef []
    let facility = noSeams {seamWait = \handle bound -> do
                              mine <- getPid handle
                              wanted <- readIORef target
                              if mine == wanted then modifyIORef' handles (handle :) >> pure Nothing else seamWait noSeams handle bound}
        setup host = do
          pid <- hosted host (readyChild hangCatcher "first" nowhere) pidBody
          writeIORef target (Just pid)
          void (hosted host (readyChild hangCatcher "second" nowhere) pidBody)
        check ending = do
          outcome <- stoppingWindow noHostSeams facility setup ending $ \_ _ gate _ -> openGate gate
          readIORef handles >>= mapM_ (void . waitForProcess)
          pure outcome
    plain <- check Nothing
    case plain of
      Left failure@(ExceptionWithContext _ cause) -> do
        show cause `shouldSatisfy` ("cleanup was not confirmed" `isInfixOf`)
        retained failure `shouldBe` []
      Right () -> expectationFailure "an unconfirmed cleanup did not fail the scope"
    writeIORef target Nothing
    both <- check (Just Boom)
    case both of
      Left failure@(ExceptionWithContext _ cause) -> do
        fromException cause `shouldBe` Just Boom
        retained failure `shouldSatisfy` any ("cleanup was not confirmed" `isInfixOf`)
      Right () -> expectationFailure "the owner's failure was not raised"

-- | The examples of a host that has ended.
endedSpec :: Spec
endedSpec = describe "Ended" $ do
  -- A host whose worker is cancelled while Starting, with a queued request "q" whose submitter is held before it withdraws, so that
  -- the slot still holds a request when the host has ended.
  let endedWithHeldSlot use = do
        gate <- newGate
        holding <- newGate
        workerVar <- newEmptyTMVarIO
        wires <- newWires
        hold <- holdSubmitter "q" holding
        let hooks =
              (startingHooks wires gate)
                { hostBeforeServing = myThreadId >>= atomically . putTMVar workerVar >> park gate
                , hostAbandoning = hold
                , hostOpen = openGate gate >> openGate holding
                }
        withHostEx noSeams hooks $ \host ->
          withSubmission host (readyChild Unbounded "q" nowhere) pidBody $ \q -> do
            bounded (awaitQueued host True)
            worker <- bounded (atomically (readTMVar workerVar))
            throwTo worker ThreadKilled
            bounded (awaitHostState host (== Ended))
            awaitReached holding
            use host holding q

  it "Ended × Submit: refused at once, whatever the slot held when it ended" $ do
    ran <- newIORef False
    endedWithHeldSlot $ \host _ _ -> do
      hostQueued host `shouldReturn` True
      withSupplied $ \handle ->
        withSubmission host (supplying handle (readyChild Unbounded "z" nowhere)) (flagged ran) $ \z -> do
          answered z >>= (`shouldSatisfy` isEnded)
          closed handle `shouldReturn` True
      hostQueued host `shouldReturn` True
    readIORef ran `shouldReturn` False

  it "Ended × Bound passes or the submitter is cancelled: not applicable, because every earlier waiter was answered and every later submission is refused without waiting" $
    endedWithHeldSlot $ \host holding q -> do
      openGate holding
      -- The earlier waiter was answered, and the slot is empty: nothing is waiting.
      answered q >>= (`shouldSatisfy` isEnded)
      hostQueued host `shouldReturn` False
      -- A later submission is refused without being placed, so nothing can come to wait.
      outcome <- try @HostFailure (hosted host (readyChild Unbounded "z" nowhere) pidBody)
      outcome `shouldSatisfy` either (\case HostEnded _ -> True; _ -> False) (const False)
      hostQueued host `shouldReturn` False

  it "Ended × Stop: idempotent; no child is ended a second time and no failure is raised a second time" $ do
    (sent, facility) <- countSignals
    workerVar <- newEmptyTMVarIO
    withHostEx facility noHostSeams {hostBeforeServing = myThreadId >>= atomically . putTMVar workerVar} $ \host -> do
      oneChild host
      worker <- bounded (atomically (readTMVar workerVar))
      throwTo worker ThreadKilled
      bounded (awaitHostState host (== Ended))
      recordStop host
      recordStop host
      hostState host `shouldReturn` Ended
    -- The one child was ended once, when the worker unwound; the stop recorded after the end ended nothing again.
    terms sent `shouldReturn` [sigTERM]

  it "Ended × Owner fails: the owner's failure is raised once, as itself, with nothing ended again" $ do
    (sent, facility) <- countSignals
    workerVar <- newEmptyTMVarIO
    outcome <- tryBoom $
      withHostEx facility noHostSeams {hostBeforeServing = myThreadId >>= atomically . putTMVar workerVar} $ \host -> do
        oneChild host
        worker <- bounded (atomically (readTMVar workerVar))
        throwTo worker ThreadKilled
        bounded (awaitHostState host (== Ended))
        throwIO Boom
    outcome `shouldBe` Left Boom
    terms sent `shouldReturn` [sigTERM]

  it "Ended × The worker ends by itself: not applicable, because Ended is final; a further cancellation of the finished worker changes nothing" $ do
    workerVar <- newEmptyTMVarIO
    withHostEx noSeams noHostSeams {hostBeforeServing = myThreadId >>= atomically . putTMVar workerVar} $ \host -> do
      oneChild host
      worker <- bounded (atomically (readTMVar workerVar))
      throwTo worker ThreadKilled
      bounded (awaitHostState host (== Ended))
      throwTo worker ThreadKilled
      hostState host `shouldReturn` Ended

causeSpec :: Spec
causeSpec = describe "Cause: how a host, or a request inside it, comes to an end" $ do
  it "Cause: a normal end ends and reaps every hosted child in reverse order of their start, including the child of a body still running, which is cancelled first" $
    withSystemTempDirectory "hosted-order" $ \directory -> do
      let order = directory <> "/order"
      held <- newHeld
      hostVar <- newEmptyTMVarIO
      pids <- newIORef []
      withLateSubmission hostVar (loggedChild Unbounded "running" order) (heldBody held) $ \a -> do
        withHost $ \host -> do
          hosted host (loggedChild hangCatcher "first" order) pidBody >>= remember pids
          atomically (putTMVar hostVar host)
          awaitHeld held >>= remember pids
        answered a >>= (`shouldSatisfy` isStopped)
      logged order `shouldReturn` ["running", "first"]
      assertReaped pids

  it "Cause: a normal end raises the failure of an unconfirmed cleanup after every other child was ended" $ do
    target <- newIORef Nothing
    handles <- newIORef []
    pids <- newIORef []
    let facility = noSeams {seamWait = \handle bound -> do
                              mine <- getPid handle
                              wanted <- readIORef target
                              if mine == wanted then modifyIORef' handles (handle :) >> pure Nothing else seamWait noSeams handle bound}
    outcome <- try @SubprocessFailure $
      withHostEx facility noHostSeams $ \host -> do
        first <- hosted host (readyChild hangCatcher "first" nowhere) pidBody
        writeIORef target (Just first)
        second <- hosted host (readyChild hangCatcher "second" nowhere) pidBody
        remember pids second
    case outcome of
      Left (SubprocessFailure message) -> message `shouldSatisfy` ("cleanup was not confirmed" `isInfixOf`)
      Right () -> expectationFailure "an unconfirmed cleanup did not fail the scope"
    -- The other child was ended and reaped; the injected one was killed, and its reap is done here.
    assertReaped pids
    readIORef handles >>= mapM_ (void . waitForProcess)

  it "Cause: a child that fails to start tells only its own submitter, closes its handles, and leaves the host serving, however many fail in a row" $
    withHost $ \host -> do
      withSupplied $ \one -> withSupplied $ \two -> withSupplied $ \three -> do
        forM_ [(one, Unbounded), (two, Unbounded), (three, Within 5000000)] $ \(handle, bound) -> do
          -- A third failure whose own bound is on the real clock must not wait for a slot a failed start left full.
          outcome <- bounded (tryWithContext @SomeException (hosted host (supplying handle (missingChild bound)) (\_ -> pure ())))
          outcome `shouldSatisfy` isStartFailure
          closed handle `shouldReturn` True
          hostState host `shouldReturn` Idle
      pids <- newIORef []
      hosted host (readyChild hangCatcher "a" nowhere) pidBody >>= remember pids
      assertAlive pids

  it "Cause: a body that fails gives its submitter that failure as itself; earlier children are untouched and the host goes on serving" $ do
    pids <- newIORef []
    withHost $ \host -> do
      hosted host (readyChild hangCatcher "a" nowhere) pidBody >>= remember pids
      outcome <- tryBoomValue (hosted host (readyChild hangCatcher "b" nowhere) (\child -> awaitReady child >> throwIO Boom))
      outcome `shouldBe` Left Boom
      assertAlive pids
      hostState host `shouldReturn` Idle
      hosted host (readyChild hangCatcher "c" nowhere) pidBody >>= remember pids
      assertAlive pids
    assertReaped pids

  it "Cause: a body cancelled because the worker was cancelled answers its submitter, ends service, and later submissions are refused; the owner's scope does not raise a cancellation that was not its own" $ do
    held <- newHeld
    workerVar <- newEmptyTMVarIO
    withHostEx noSeams noHostSeams {hostBeforeServing = myThreadId >>= atomically . putTMVar workerVar} $ \host -> do
      withSubmission host (readyChild Unbounded "a" nowhere) (heldBody held) $ \a -> do
        _ <- awaitHeld held
        worker <- bounded (atomically (readTMVar workerVar))
        throwTo worker ThreadKilled
        answered a >>= (`shouldSatisfy` isEnded)
      bounded (awaitHostState host (== Ended))
      outcome <- try @HostFailure (hosted host (readyChild Unbounded "b" nowhere) pidBody)
      outcome `shouldSatisfy` either (\case HostEnded _ -> True; _ -> False) (const False)

  it "Cause: the owner's body fails or is cancelled, and every child is ended and reaped with the cleanup failure retained beside the owner's failure" $ do
    target <- newIORef Nothing
    handles <- newIORef []
    let facility = noSeams {seamWait = \handle bound -> do
                              mine <- getPid handle
                              wanted <- readIORef target
                              if mine == wanted then modifyIORef' handles (handle :) >> pure Nothing else seamWait noSeams handle bound}
    outcome <- tryWithContext @SomeException $
      withHostEx facility noHostSeams $ \host -> do
        first <- hosted host (readyChild hangCatcher "first" nowhere) pidBody
        writeIORef target (Just first)
        throwIO Boom
    case outcome of
      Left failure@(ExceptionWithContext _ cause) -> do
        fromException cause `shouldBe` Just Boom
        retained failure `shouldSatisfy` any ("cleanup was not confirmed" `isInfixOf`)
      Right () -> expectationFailure "the owner's failure was not raised"
    readIORef handles >>= mapM_ (void . waitForProcess)

  it "Cause: the host keeps a child that already exited by itself, and its descendants, until it ends, and then reaps the child and ends the descendants" $ do
    descendant <- newIORef 0
    pids <- newIORef []
    let script = "sleep 300 </dev/null >/dev/null 2>&1 & echo \"ready $!\"; exit 0"
    withHost $ \host -> do
      pid <- hosted host (childSpec hangCatcher (shell script [])) $ \child -> do
        line <- awaitReadyLine child
        writeIORef descendant (read (last (words line)))
        pure (childPid child)
      remember pids pid
      -- The helper has exited, unreaped (a zombie still answers the null signal), and its descendant is still running.
      (readIORef descendant >>= goneAndReaped) `shouldReturn` False
      assertAlive pids
    assertReaped pids
    (readIORef descendant >>= goneAndReaped) `shouldReturn` True

-- | The three places an abandonment can race the worker for the handles of a request.
racesSpec :: Spec
racesSpec = describe "An abandonment racing the worker (rule A)" $ do
  it "Race: an abandonment racing the worker taking the request leaves its handles closed exactly once, by the worker, and the body never entered" $ do
    gate <- newGate
    ran <- newIORef False
    withSupplied $ \handle ->
      withHostEx noSeams noHostSeams {hostTaking = park gate, hostOpen = openGate gate} $ \host ->
        withSubmission host (supplying handle (readyChild (Within 60000000) "a" nowhere)) (flagged ran) $ \a -> do
          awaitReached gate
          hostState host `shouldReturn` ServingEmpty
          cancelSubmitter a
          answered a >>= (`shouldSatisfy` isCancellation)
          -- The worker has the request: the submitter did not close the handles.
          closed handle `shouldReturn` False
          openGate gate
          bounded (awaitHostState host (== Idle))
          closed handle `shouldReturn` True
          readIORef ran `shouldReturn` False

  it "Race: an abandonment racing the child's acquisition leaves its handles closed exactly once, by the worker, and the body never entered; the child, which exists, stays hosted" $ do
    gate <- newGate
    ran <- newIORef False
    pids <- newIORef []
    withSupplied $ \handle ->
      withHostEx noSeams {seamSpawned = \process -> getPid process >>= maybe (pure ()) (remember pids) >> park gate} noHostSeams {hostOpen = openGate gate} $ \host ->
        withSubmission host (supplying handle (readyChild (Within 60000000) "a" nowhere)) (flagged ran) $ \a -> do
          awaitReached gate
          cancelSubmitter a
          answered a >>= (`shouldSatisfy` isCancellation)
          closed handle `shouldReturn` False
          openGate gate
          bounded (awaitHostState host (== Idle))
          closed handle `shouldReturn` True
          readIORef ran `shouldReturn` False
          assertAlive pids
    assertReaped pids

  it "Race: an abandonment racing the entry of the body leaves its handles closed exactly once, by the worker, and the body never entered" $ do
    gate <- newGate
    ran <- newIORef False
    withSupplied $ \handle ->
      withHostEx noSeams noHostSeams {hostEntering = park gate, hostOpen = openGate gate} $ \host ->
        withSubmission host (supplying handle (readyChild (Within 60000000) "a" nowhere)) (flagged ran) $ \a -> do
          awaitReached gate
          cancelSubmitter a
          answered a >>= (`shouldSatisfy` isCancellation)
          closed handle `shouldReturn` False
          openGate gate
          bounded (awaitHostState host (== Idle))
          closed handle `shouldReturn` True
          readIORef ran `shouldReturn` False

  it "Race: an abandonment that comes after the entry of the body leaves its handles open, the caller's to close" $ do
    held <- newHeld
    withSupplied $ \handle ->
      withHost $ \host -> do
        withSubmission host (supplying handle (readyChild (Within 60000000) "a" nowhere)) (heldBody held) $ \a -> do
          _ <- awaitHeld held
          cancelSubmitter a
          answered a >>= (`shouldSatisfy` isCancellation)
          releaseHeld held
          bounded (awaitHostState host (== Idle))
        hIsOpen handle `shouldReturn` True

-- | The cleanup blocks the host itself adds, each with a cancellation delivered into it (the audit of the module header): the
-- cancellation is remembered, the cleanup finished, and what is raised keeps the failure being handled and every diagnostic.
cleanupSpec :: Spec
cleanupSpec = describe "A cancellation delivered into a cleanup of the host" $ do
  let reap = quick {boundReap = 300000}

  it "Cleanup: the submitter's hold before it withdraws its request: the cancellation is remembered, the request is withdrawn and its handles closed, and the host stopped failure is kept beside the cancellation" $ do
    gate <- newGate
    wires <- newWires
    holding <- newGate
    hold <- holdSubmitter "q" holding
    withSupplied $ \handle ->
      withHostEx noSeams ((startingHooks wires gate) {hostAbandoning = hold}) $ \host ->
        withSubmission host (supplying handle (readyChild Unbounded "q" nowhere)) pidBody $ \q -> do
          bounded (awaitQueued host True)
          recordStop host
          awaitReached holding
          cancelSubmitter q
          answer <- answered q
          answer `shouldSatisfy` isCancellation
          either retained (const []) answer `shouldSatisfy` any ("stopped before it answered" `isInfixOf`)
          closed handle `shouldReturn` True
          hostQueued host `shouldReturn` False

  it "Cleanup: the submitter's close of its withdrawn request's handles: the cancellation is remembered, the close finished (a handle that cannot be flushed is closed within the reap bound), and the failure and the unflushed diagnostic are kept beside it" $ do
    gate <- newGate
    wires <- newWires
    closing <- newGate
    once <- parkOnce closing
    (reading, writing) <- blockedPipe
    (do
        withHostUsing reap noSeams ((startingHooks wires gate) {hostClosing = once}) $ \host ->
          withSubmission host ((readyChild Unbounded "a" nowhere) {specStdout = CallerHandle writing}) pidBody $ \a -> do
            bounded (awaitQueued host True)
            recordStop host
            awaitReached closing
            cancelSubmitter a
            answer <- answered a
            answer `shouldSatisfy` isCancellation
            let kept = either retained (const []) answer
            kept `shouldSatisfy` any ("stopped before it answered" `isInfixOf`)
            kept `shouldSatisfy` any ("could not be flushed" `isInfixOf`)
            hIsOpen writing `shouldReturn` False)
      `finally` hClose reading

  it "Cleanup: the worker's close of a claimed request's handles: the worker's cancellation is remembered, the close finished and the handle closed, and the failure it was handling is raised by the owner's scope beside it as a cleanup that was not confirmed" $ do
    taking <- newGate
    closing <- newGate
    once <- parkOnce closing
    workerVar <- newEmptyTMVarIO
    ran <- newIORef False
    outcome <-
      tryWithContext @SomeException . withSupplied $ \handle ->
        withHostEx noSeams noHostSeams {hostBeforeServing = myThreadId >>= atomically . putTMVar workerVar, hostTaking = park taking, hostClosing = once, hostOpen = openGate taking} $ \host ->
          withSubmission host (supplying handle (readyChild (Within 60000000) "a" nowhere)) (flagged ran) $ \a -> do
            awaitReached taking
            cancelSubmitter a
            answered a >>= (`shouldSatisfy` isCancellation)
            openGate taking
            -- The worker has the request and the submitter has gone: the entry is refused, and the close is under way.
            awaitReached closing
            worker <- bounded (atomically (readTMVar workerVar))
            throwTo worker ThreadKilled
            bounded (awaitHostState host (== Ended))
            closed handle `shouldReturn` True
            readIORef ran `shouldReturn` False
    case outcome of
      Left (ExceptionWithContext _ failure) -> case fromException failure of
        Just (SubprocessFailure message) ->
          message `shouldSatisfy` (\text -> "cleanup was not confirmed" `isInfixOf` text && "was abandoned before its body was entered" `isInfixOf` text)
        Nothing -> expectationFailure ("the owner's scope raised " <> show failure)
      Right () -> expectationFailure "the failure the worker was handling was not raised by the owner's scope"

-- | Rule F: the limit of a body that is not cancellable.
cancellabilitySpec :: Spec
cancellabilitySpec = describe "A body outside the cancellability precondition (rule F)" $ do
  it "a body that ignores its cancellation holds the scope's join until it lets go, and meanwhile reports no child ended or reaped that is not, answers its submitter, and never replaces the owner's failure" $ do
    stubborn <- newEmptyMVar
    entered <- newEmptyTMVarIO
    hostVar <- newEmptyTMVarIO
    seen <- newEmptyTMVarIO
    finished <- newIORef False
    let body child = do
          awaitReady child
          atomically (putTMVar entered (childPid child))
          -- Outside the precondition: an uninterruptible wait, with no opening registered for the scope.
          uninterruptibleMask_ (readMVar stubborn >> writeIORef finished True)
          pure (childPid child)
    withLateSubmission hostVar (readyChild Unbounded "a" nowhere) body $ \a -> do
      let observe = do
            host <- atomically (readTMVar hostVar)
            -- The stop is recorded and the worker cannot be cancelled: the owner's scope is waiting for the body.
            (do
                bounded (awaitHostState host (== Stopping))
                answer <- answered a
                pid <- bounded (atomically (readTMVar entered))
                reaped <- goneAndReaped pid
                atomically (putTMVar seen (isStopped answer, not reaped)))
              `finally` void (tryPutMVar stubborn ())
      withOwnedThread observe $ \_ _ -> do
        outcome <- tryBoom $
          withHost $ \host -> do
            atomically (putTMVar hostVar host)
            void (bounded (atomically (readTMVar entered)))
            throwIO Boom
        outcome `shouldBe` Left Boom
        bounded (atomically (readTMVar seen)) `shouldReturn` (True, True)
        readIORef finished `shouldReturn` True
        pid <- bounded (atomically (readTMVar entered))
        goneAndReaped pid `shouldReturn` True

-- | A captured run: the shape the display-helper suites use.
capturedSpec :: Spec
capturedSpec = describe "A captured run on a host" $ do
  it "gives the child the input it was given and the end of it" $
    withHost $ \host -> do
      (status, out, err) <- hostedCaptured host hangCatcher (proc "cat" []) "typed\n"
      (status, out, err) `shouldBe` (ExitSuccess, "typed\n", "")

  it "answers the status and what the child wrote, and leaves the child's group unended until the host ends" $ do
    descendant <- newIORef 0
    -- The leader exits at once, writing the identifier of a descendant that stays in its group.
    let script = "sleep 300 </dev/null >/dev/null 2>&1 & echo $!; echo oops >&2; exit 3"
    withHost $ \host -> do
      (status, out, err) <- hostedCaptured host hangCatcher (shell script []) ""
      status `shouldBe` ExitFailure 3
      err `shouldBe` "oops\n"
      writeIORef descendant (read (takeWhile (/= '\n') out))
      (readIORef descendant >>= goneAndReaped) `shouldReturn` False
    (readIORef descendant >>= goneAndReaped) `shouldReturn` True
