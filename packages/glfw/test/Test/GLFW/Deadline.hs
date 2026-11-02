-- | Examples for the process-level deadline on native initialization (#586).
--
-- The guard ("Hetoimasia.GLFW.Internal.Deadline") is driven directly with a
-- recording exit and through a session over the test seam, whose scripted
-- @glfwInit@ can block on a gate the example holds. Nothing here sleeps for
-- correctness: every ordering is forced by an 'MVar' or a transaction, and a
-- bound only stops an example that has already hung. The deadlines in these
-- examples are short only where the example needs the bound to pass; no example
-- depends on how long that takes.
--
-- The one example that ends a real process runs the production exit in a child
-- of this very executable, whose main thread is blocked across a safe foreign
-- call, and bounds the child from outside ('childSpec').
module Test.GLFW.Deadline (spec, runChild, childVariable) where

import Control.Concurrent (ThreadId, forkIO, killThread)
import Control.Concurrent.MVar (MVar, newEmptyMVar, putMVar, takeMVar, tryPutMVar, tryReadMVar)
import Control.Exception (AsyncException (ThreadKilled), ErrorCall (ErrorCall), SomeException, fromException, throwIO, try)
import Control.Monad (void, when)
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import Data.List (isInfixOf)
import qualified Data.Text as Text
import Foreign.C.Types (CInt (CInt), CUInt (CUInt))
import GHC.Conc (ThreadStatus (ThreadDied, ThreadFinished), listThreads, threadStatus)
import Hetoimasia.Foundation.Resource (withScoped)
import Hetoimasia.GLFW.Internal.Deadline (guardInitialization, guardInitializationWithin)
import Hetoimasia.GLFW.Seam
import Hetoimasia.GLFW.Session
import System.Environment (getEnvironment, getExecutablePath)
import System.Exit (ExitCode (ExitFailure, ExitSuccess))
import System.IO (hFlush, hPutStrLn, stderr, stdout)
import System.Process (CreateProcess (env), proc, readCreateProcessWithExitCode)
import System.Timeout (timeout)
import Test.Hspec (Expectation, Spec, describe, expectationFailure, it, shouldBe, shouldReturn, shouldSatisfy)

spec ∷ Spec
spec = do
  describe "GLFW initialization deadline" $ do
    it "leaves a call without a deadline exactly as it was"
      (bounded testNoDeadline)
    it "lets a call that returns in time return, never exits, and leaves no thread behind"
      (bounded testReturnsInTime)
    it "returns a false answer untouched, with no exit and no thread left"
      (bounded testFalseReturn)
    it "propagates a call's exception, with no exit and no thread left"
      (bounded testRaises)
    it "retires and joins its thread when the call is cancelled"
      (bounded testCancelled)
    it "reports an expired bound, then ends the process with the documented status, once"
      (bounded testExpires)
    it "ends the process even when the report blocks for good"
      (bounded testReportBlocks)
    it "ends the process even when the report throws"
      (bounded testReportThrows)
    it "decides a call that returns while the report runs as expired, exactly once"
      (bounded testCompetingCompletionAndExpiry)
    it "protects every later initialization, and a retired timer cannot end a later one"
      (bounded testSequential)

  describe "GLFW session entry under a deadline" $ do
    it "enters a session whose initialization returns in time, as it does without a deadline"
      (bounded testSessionReturnsInTime)
    it "keeps a false initialization a typed entry failure, with no exit and no thread left"
      (bounded testSessionFalseInitialization)
    it "reports an expired initialization with the backend, bound and status, and asks the process to end"
      (bounded testSessionExpires)
    it "protects the second session of a process as it protects the first"
      (bounded testSessionsSequential)

  describe "GLFW initialization deadline in a process" $ do
    it "ends a child whose main thread is blocked in a safe native call, with the documented status and diagnostic"
      (childSpec "expire" childExpires)
    it "lets a child whose safe native call returns in time exit normally, with no diagnostic"
      (childSpec "return" childReturns)

-- ---------------------------------------------------------------------------
-- The guard

-- | A recording exit and report, and the gates an example holds.
data Rig = Rig
  { rigExits ∷ IORef [Int]
  , rigReports ∷ IORef [InitializationExpiry]
  }

newRig ∷ IO Rig
newRig = Rig <$> newIORef [] <*> newIORef []

recordExit ∷ Rig → Int → IO ()
recordExit rig status = atomicModifyIORef' (rigExits rig) (\seen → (seen <> [status], ()))

recordReport ∷ Rig → InitializationExpiry → IO ()
recordReport rig expiry = atomicModifyIORef' (rigReports rig) (\seen → (seen <> [expiry], ()))

deadlineOf ∷ Int → (InitializationExpiry → IO ()) → Maybe InitializationDeadline
deadlineOf bound report = Just InitializationDeadline {deadlineBoundMicroseconds = bound, deadlineReport = report}

-- | An hour: a bound that never passes during an example.
neverPasses ∷ Int
neverPasses = 3_600_000_000

-- | A bound that has passed by the time the timer thread looks.
passed ∷ Int
passed = 1

-- | The threads that are alive now.
alive ∷ IO [ThreadId]
alive = do
  threads ← listThreads
  statuses ← traverse threadStatus threads
  pure [thread | (thread, status) ← zip threads statuses, status `notElem` [ThreadFinished, ThreadDied]]

-- | Run an action and answer the threads it left alive.
leaving ∷ IO a → IO (a, [ThreadId])
leaving action = do
  before ← alive
  result ← action
  after ← alive
  pure (result, [thread | thread ← after, thread `notElem` before])

testNoDeadline ∷ Expectation
testNoDeadline = do
  rig ← newRig
  (result, left) ← leaving (guardInitialization (recordExit rig) "x11" Nothing (pure (42 ∷ Int)))
  result `shouldBe` 42
  left `shouldBe` []
  readIORef (rigExits rig) `shouldReturn` []

testReturnsInTime ∷ Expectation
testReturnsInTime = do
  rig ← newRig
  (result, left) ←
    leaving (guardInitialization (recordExit rig) "cocoa" (deadlineOf neverPasses (recordReport rig)) (pure True))
  result `shouldBe` True
  left `shouldBe` []
  readIORef (rigExits rig) `shouldReturn` []
  readIORef (rigReports rig) `shouldReturn` []

testFalseReturn ∷ Expectation
testFalseReturn = do
  rig ← newRig
  (result, left) ←
    leaving (guardInitialization (recordExit rig) "cocoa" (deadlineOf neverPasses (recordReport rig)) (pure False))
  result `shouldBe` False
  left `shouldBe` []
  readIORef (rigExits rig) `shouldReturn` []

testRaises ∷ Expectation
testRaises = do
  rig ← newRig
  (outcome, left) ←
    leaving . try @SomeException $
      guardInitialization (recordExit rig) "cocoa" (deadlineOf neverPasses (recordReport rig)) (throwIO (ErrorCall "native raised") ∷ IO ())
  fmap (fromException @ErrorCall) (either Just (const Nothing) outcome) `shouldBe` Just (Just (ErrorCall "native raised"))
  left `shouldBe` []
  readIORef (rigExits rig) `shouldReturn` []

testCancelled ∷ Expectation
testCancelled = do
  rig ← newRig
  inside ← newEmptyMVar
  gate ← newEmptyMVar ∷ IO (MVar ())
  done ← newEmptyMVar
  before ← alive
  worker ←
    forkIO $
      (try @SomeException (guardInitialization (recordExit rig) "cocoa" (deadlineOf neverPasses (recordReport rig)) (putMVar inside () >> takeMVar gate)) >>= putMVar done)
  takeMVar inside
  killThread worker
  outcome ← takeMVar done
  either (\failure → fromException failure == Just ThreadKilled) (const False) outcome `shouldBe` True
  after ← alive
  [thread | thread ← after, thread `notElem` before, thread /= worker] `shouldBe` []
  readIORef (rigExits rig) `shouldReturn` []

testExpires ∷ Expectation
testExpires = do
  rig ← newRig
  released ← newEmptyMVar
  order ← newIORef ([] ∷ [String])
  let note step = atomicModifyIORef' order (\seen → (seen <> [step], ()))
      exit status = note "exit" >> recordExit rig status >> putMVar released ()
      report expiry = note "report" >> recordReport rig expiry
  result ←
    guardInitialization exit "cocoa" (deadlineOf passed report) (takeMVar released >> pure ("returned" ∷ String))
  result `shouldBe` "returned"
  readIORef order `shouldReturn` ["report", "exit"]
  readIORef (rigExits rig) `shouldReturn` [initializationTimeoutStatus]
  readIORef (rigReports rig)
    `shouldReturn` [InitializationExpiry {expiryBackend = "cocoa", expiryBoundMicroseconds = passed, expiryStatus = initializationTimeoutStatus}]
  initializationTimeoutStatus `shouldSatisfy` (`notElem` [0, 1, 2, 3, 130])

testReportBlocks ∷ Expectation
testReportBlocks = do
  rig ← newRig
  released ← newEmptyMVar
  forever' ← newEmptyMVar ∷ IO (MVar ())
  let exit status = recordExit rig status >> putMVar released ()
      report _ = takeMVar forever'
  -- A short grace stands for the production one, which only the child example
  -- below crosses for real.
  void (guardInitializationWithin 1_000 exit "cocoa" (deadlineOf passed report) (takeMVar released))
  readIORef (rigExits rig) `shouldReturn` [initializationTimeoutStatus]
  reportGrace `shouldSatisfy` (> 0)
  putMVar forever' ()

testReportThrows ∷ Expectation
testReportThrows = do
  rig ← newRig
  released ← newEmptyMVar
  let exit status = recordExit rig status >> putMVar released ()
      report _ = throwIO (ErrorCall "the logger failed")
  -- The grace is an hour: the exit comes at once only because a report that throws has finished, as far as the guard
  -- is concerned; were its failure waited out, the example's own bound would fail it long before.
  void (guardInitializationWithin neverPasses exit "cocoa" (deadlineOf passed report) (takeMVar released))
  readIORef (rigExits rig) `shouldReturn` [initializationTimeoutStatus]

testCompetingCompletionAndExpiry ∷ Expectation
testCompetingCompletionAndExpiry = do
  rig ← newRig
  reporting ← newEmptyMVar
  finishReport ← newEmptyMVar
  callReturns ← newEmptyMVar
  let report expiry = recordReport rig expiry >> putMVar reporting () >> takeMVar finishReport
  worker ← newEmptyMVar
  void . forkIO $
    guardInitialization (recordExit rig) "cocoa" (deadlineOf passed report) (takeMVar callReturns >> pure ()) >>= putMVar worker
  -- The bound passes and the report starts while the call is still blocked; the
  -- call then returns. The guard has already decided: expired.
  takeMVar reporting
  readIORef (rigExits rig) `shouldReturn` []
  putMVar callReturns ()
  tryReadMVar worker `shouldReturn` Nothing
  putMVar finishReport ()
  takeMVar worker
  readIORef (rigExits rig) `shouldReturn` [initializationTimeoutStatus]
  length <$> readIORef (rigReports rig) `shouldReturn` 1

testSequential ∷ Expectation
testSequential = do
  rig ← newRig
  -- A first call returns in time under a deadline.
  (_, left) ← leaving (guardInitialization (recordExit rig) "cocoa" (deadlineOf neverPasses (recordReport rig)) (pure ()))
  left `shouldBe` []
  readIORef (rigExits rig) `shouldReturn` []
  -- A later call that does not return is protected by a timer of its own.
  released ← newEmptyMVar
  void (guardInitialization (\status → recordExit rig status >> putMVar released ()) "cocoa" (deadlineOf passed (recordReport rig)) (takeMVar released))
  readIORef (rigExits rig) `shouldReturn` [initializationTimeoutStatus]
  -- And a call after that, in time again, is not ended by anything left over.
  (_, again) ← leaving (guardInitialization (recordExit rig) "cocoa" (deadlineOf neverPasses (recordReport rig)) (pure ()))
  again `shouldBe` []
  readIORef (rigExits rig) `shouldReturn` [initializationTimeoutStatus]

-- ---------------------------------------------------------------------------
-- A session

-- | A session configuration with a deadline over the recording rig.
configWith ∷ Rig → Int → SessionConfig
configWith rig bound = defaultSessionConfig {initializationDeadline = deadlineOf bound (recordReport rig)}

testSessionReturnsInTime ∷ Expectation
testSessionReturnsInTime = do
  rig ← newRig
  seam ← newSeam defaultScript
  (backend, left) ←
    leaving (asProcessMainThread seam (withScoped (seamSession seam (configWith rig neverPasses)) (pure . sessionBackend)))
  backend `shouldBe` X11
  left `shouldBe` []
  calls ← seamCalls seam
  ExitProcess initializationTimeoutStatus `shouldSatisfy` (`notElem` calls)
  readIORef (rigReports rig) `shouldReturn` []

testSessionFalseInitialization ∷ Expectation
testSessionFalseInitialization = do
  rig ← newRig
  seam ← newSeam defaultScript {scriptInitialize = \reporter → reportError reporter 0x00010008 "X11: missing" >> pure False}
  (outcome, left) ←
    leaving . try @SomeException $
      asProcessMainThread seam (withScoped (seamSession seam (configWith rig neverPasses)) (\_ → pure ()))
  fmap (fromException @NativeFailure) (either Just (const Nothing) outcome)
    `shouldSatisfy` maybe False (maybe False ((== NativeCallFailed) . nativeOutcome))
  left `shouldBe` []
  calls ← seamCalls seam
  ExitProcess initializationTimeoutStatus `shouldSatisfy` (`notElem` calls)

testSessionExpires ∷ Expectation
testSessionExpires = do
  rig ← newRig
  reported ← newEmptyMVar
  let report expiry = recordReport rig expiry >> putMVar reported ()
      config = defaultSessionConfig {initializationDeadline = deadlineOf passed report}
  seam ← newSeam defaultScript {scriptInitialize = \_ → takeMVar reported >> pure True}
  backend ← asProcessMainThread seam (withScoped (seamSession seam config) (pure . sessionBackend))
  backend `shouldBe` X11
  calls ← seamCalls seam
  length (filter (== ExitProcess initializationTimeoutStatus) calls) `shouldBe` 1
  readIORef (rigReports rig)
    `shouldReturn` [InitializationExpiry {expiryBackend = "x11", expiryBoundMicroseconds = passed, expiryStatus = initializationTimeoutStatus}]

testSessionsSequential ∷ Expectation
testSessionsSequential = do
  rig ← newRig
  gate ← newEmptyMVar
  attempts ← newIORef (0 ∷ Int)
  seam ←
    newSeam
      defaultScript
        { scriptInitialize = \_ → do
            n ← atomicModifyIORef' attempts (\seen → (seen + 1, seen + 1))
            -- The first initialization returns at once. The second does not
            -- return until its deadline's report has run.
            when (n == 2) (takeMVar gate)
            pure True
        }
  let enter config = asProcessMainThread seam (withScoped (seamSession seam config) (pure . sessionBackend))
  _ ← enter (configWith rig neverPasses)
  calls1 ← seamCalls seam
  ExitProcess initializationTimeoutStatus `shouldSatisfy` (`notElem` calls1)
  _ ← enter defaultSessionConfig {initializationDeadline = deadlineOf passed (\expiry → recordReport rig expiry >> void (tryPutMVar gate ()))}
  calls2 ← seamCalls seam
  length (filter (== ExitProcess initializationTimeoutStatus) calls2) `shouldBe` 1
  length <$> readIORef (rigReports rig) `shouldReturn` 1

-- ---------------------------------------------------------------------------
-- A real process

-- | The variable that makes this executable run a child scenario instead of the
-- suite. Read once, in 'Main', before Hspec.
childVariable ∷ String
childVariable = "HETOIMASIA_GLFW_DEADLINE_CHILD"

foreign import ccall safe "sleep" c_sleep ∷ CUInt → IO CUInt

foreign import ccall unsafe "_exit" c_exit ∷ CInt → IO ()

-- | The child scenario. The main thread is blocked across a safe foreign call
-- (@sleep@ for an hour), bracketed by the real guard with the real exit
-- (@_exit@, as the production table binds it) and a report that writes the
-- diagnostic on standard error. Nothing in the child ends the sleep: only the
-- guard can end this process before the hour.
runChild ∷ String → IO ()
runChild scenario = do
  let report expiry =
        hPutStrLn stderr . Text.unpack $
          "initialization of backend "
            <> expiryBackend expiry
            <> " exceeded its bound of "
            <> Text.pack (show (expiryBoundMicroseconds expiry))
            <> " microseconds; ending the process with status "
            <> Text.pack (show (expiryStatus expiry))
      exit status = hFlush stderr >> c_exit (fromIntegral status)
  case scenario of
    "expire" → do
      -- The bound is short; the sleep is an hour. The guard ends the process.
      void (guardInitialization exit "cocoa" (deadlineOf 200_000 report) (c_sleep 3600))
      hPutStrLn stderr "the child outlived its deadline"
    _ → do
      -- A call that returns in time: the sleep is zero seconds.
      void (guardInitialization exit "cocoa" (deadlineOf neverPasses report) (c_sleep 0))
      hPutStrLn stdout "returned" >> hFlush stdout

-- | Run this executable as the child and judge what it did. The child is
-- bounded from outside: if it has not ended in thirty seconds the guard did not
-- work, and the process library stops it when the bound abandons the call.
childSpec ∷ String → (ExitCode → String → String → Expectation) → Expectation
childSpec scenario judge = do
  self ← getExecutablePath
  environment ← getEnvironment
  let process = (proc self []) {env = Just ((childVariable, scenario) : filter ((/= childVariable) . fst) environment)}
  outcome ← timeout 30_000_000 (readCreateProcessWithExitCode process "")
  case outcome of
    Nothing → expectationFailure "the child did not end within its bound"
    Just (code, out, err) → judge code out err

childExpires ∷ ExitCode → String → String → Expectation
childExpires code out err = do
  code `shouldBe` ExitFailure (fromIntegral initializationTimeoutStatus)
  out `shouldBe` ""
  err `shouldSatisfy` ("initialization of backend cocoa exceeded its bound of 200000 microseconds" `isInfixOf`)
  err `shouldSatisfy` ("status 75" `isInfixOf`)
  err `shouldSatisfy` (not . ("outlived" `isInfixOf`))

childReturns ∷ ExitCode → String → String → Expectation
childReturns code out err = do
  code `shouldBe` ExitSuccess
  out `shouldBe` "returned\n"
  err `shouldBe` ""

bounded ∷ Expectation → Expectation
bounded action = do
  finished ← timeout (30 * 1000 * 1000) action
  case finished of
    Just () → pure ()
    Nothing → expectationFailure "the example did not finish within its bound"
