-- | Session lifecycles no shared session can host.
--
-- GLFW allows one session per process, and the shared fixture holds that one
-- for the whole run, so entering and leaving sessions in sequence, a forced
-- initialization failure and its rollback, a session over a faulting or tracing
-- native table, and a monitor identity carried from one session into the next
-- each need a process of their own. Each example here starts this same
-- executable as a child with 'privateSessionFlag' and a scenario name; the
-- child runs that scenario's checks in order on its own process main thread,
-- prints one line per check, and exits non-zero if any failed. A dry run or a
-- selection that skips these examples starts no child.
--
-- Neither side starts without consent. The parent asks the run's 'Gate' before
-- it starts a child, so an unapproved run refuses the example and launches
-- nothing; the child inherits the parent's environment, so an approved run's
-- consent carries to it and it is never asked again. A child started directly
-- from an unapproved shell reads its own environment and refuses, on stderr
-- with 'refusedExit', before any scenario is looked up or any session entered.
module Test.GLFW.Native.Private
  ( spec
  , privateSessionFlag
  , runScenario

    -- * For the headless regressions
  , launchWith
  , childPlan
  , refusedExit
  , unknownScenarioExit
  ) where

import Control.Concurrent.STM (atomically)
import Control.Exception (ErrorCall (ErrorCall), SomeException, displayException, fromException, throw, try)
import Control.Monad (unless, when)
import Data.IORef (IORef, modifyIORef', newIORef, readIORef, writeIORef)
import Foreign.Ptr (nullFunPtr)
import qualified Data.Text as Text
import Hetoimasia.Foundation.Failure
  ( FailureCause (..)
  , FailureEvidence (..)
  , FailureOrigin (..)
  , OperationContext (..)
  , failureEvidence
  , operation
  , operationText
  )
import Hetoimasia.Foundation.Log (componentText)
import Hetoimasia.Foundation.Messaging.Payload (preparedValue)
import Hetoimasia.Foundation.Messaging.Snapshot (observedValue, readSnapshot)
import Hetoimasia.Foundation.Resource (allocComposite, withScoped)
import Hetoimasia.GLFW.Internal.Native
  ( glfwPlatformUnavailable
  , installedMonitorCallbackForCheck
  , pollEventsForCheck
  , productionNative
  , setWindowSizeForCheck
  , waitEventsForCheck
  )
import Hetoimasia.GLFW.Internal.Monitor (MonitorCallbackStorage (..), MonitorNative (..))
import Hetoimasia.GLFW.Internal.Session (Native (..), WindowCallbacks (..), sessionAssembly)
import Hetoimasia.GLFW.Internal.Window (windowStep)
import Hetoimasia.GLFW.Monitor
import Hetoimasia.GLFW.Session
import Hetoimasia.GLFW.Window
import System.Environment (getExecutablePath)
import System.Exit (ExitCode (..), exitFailure, exitWith)
import System.IO (hFlush, hPutStrLn, stderr, stdout)
import System.Process (readProcessWithExitCode)
import Test.GLFW.Native.Consent (Consent, Refusal, refusalMessage)
import Test.GLFW.Native.Support (Gate, admit, hostBackend)
import Test.Hspec (Spec, describe, expectationFailure, it, shouldContain)

-- | The argument that makes this executable a private-session child.
privateSessionFlag ∷ String
privateSessionFlag = "--private-session"

spec ∷ Gate → Spec
spec gate = describe "private sessions in a child process" $ do
  it "enters and leaves real sessions in sequence, fails a forced initialization, and enters again after its rollback" $
    privateScenario gate "session-lifecycle"

  it "rethrows a fault raised inside a real native callback at the owner boundary" $
    privateScenario gate "callback-fault"

  it "detaches the real monitor callback before termination, frees it last, and never resolves an ended session's identity" $
    privateScenario gate "monitor-lifecycle"

privateScenario ∷ Gate → String → IO ()
privateScenario gate = launchWith gate $ \name → do
  executable ← getExecutablePath
  readProcessWithExitCode executable [privateSessionFlag, name] ""

-- | Run one scenario through a launcher, once the gate admits the run, and
-- check that the child reported every check passed. A refused run raises the
-- refusal on the example's thread and never calls the launcher.
launchWith ∷ Gate → (String → IO (ExitCode, String, String)) → String → IO ()
launchWith gate launch name = do
  _ ← admit gate
  (status, out, err) ← launch name
  unless (status == ExitSuccess) $
    expectationFailure ("the private " <> name <> " process exited " <> show status <> ":\n" <> out <> err)
  out `shouldContain` ("glfw-native-tests " <> name <> ": every check passed")

-- | The child's exit when its own environment carries no consent.
refusedExit ∷ ExitCode
refusedExit = ExitFailure 3

-- | The child's exit for a scenario it does not know.
unknownScenarioExit ∷ ExitCode
unknownScenarioExit = ExitFailure 2

-- | What the child does with its consent and scenario name: exit with a
-- message, or run these checks. Consent is decided before the scenario is
-- looked up, so an unapproved child refuses whatever it was asked for.
childPlan ∷ Either Refusal Consent → String → Either (ExitCode, String) [(String, IO String)]
childPlan consent name = case consent of
  Left refusal → Left (refusedExit, "glfw-native-tests " <> name <> ": " <> refusalMessage refusal)
  Right _ → case lookup name scenarios of
    Nothing → Left (unknownScenarioExit, "glfw-native-tests: unknown private session scenario " <> show name)
    Just checks → Right checks

-- | Run one scenario as the child process, then exit.
runScenario ∷ Either Refusal Consent → String → IO ()
runScenario consent name = case childPlan consent name of
  Left (code, message) → do
    hPutStrLn stderr message
    exitWith code
  Right checks → do
    failures ← newIORef (0 ∷ Int)
    mapM_ (runCheck failures) checks
    count ← readIORef failures
    if count == 0
      then putStrLn ("glfw-native-tests " <> name <> ": every check passed")
      else do
        putStrLn ("glfw-native-tests " <> name <> ": " <> show count <> " check(s) failed")
        exitFailure

scenarios ∷ [(String, [(String, IO String)])]
scenarios =
  [ ( "session-lifecycle"
    , [ ("enters and leaves a real session", enterAndLeave)
      , ("enters a second session after a complete teardown", enterAndLeave)
      , ("observes an initialization error before any event polling", initializationError)
      , ("enters a session after the failed initialization rolled back", enterAndLeave)
      ]
    )
  , ( "callback-fault"
    , [("rethrows a fault raised inside a real native callback at the owner boundary", callbackFault)]
    )
  , ( "monitor-lifecycle"
    , [ ("detaches the installed monitor callback before termination and frees it after the last native call", monitorTeardown)
      , ("never resolves a monitor identity from a completed session in a later session", monitorAcrossSessions)
      ]
    )
  ]

runCheck ∷ IORef Int → (String, IO String) → IO ()
runCheck failures (name, check) = do
  outcome ← try check
  case outcome of
    Right detail → putStrLn ("ok   " <> name <> ": " <> detail)
    Left (failure ∷ SomeException) → do
      modifyIORef' failures (+ 1)
      putStrLn ("FAIL " <> name <> ": " <> displayException failure)
  hFlush stdout

enterAndLeave ∷ IO String
enterAndLeave = do
  (backend, reports) ← withSession defaultSessionConfig $ \session → do
    reports ← takeAsynchronousReports session
    pure (sessionBackend session, reports)
  unless (backend == hostBackend) $
    failCheck ("the session selected " <> show backend <> ", not " <> show hostBackend)
  pure ("backend " <> show backend <> ", asynchronous reports " <> show reports)

-- | A production table whose size callback copies a payload that raises, so the
-- fault is raised inside the model's trampoline while GLFW is calling it.
--
-- Cocoa calls the size callback inside the resize itself; X11 delivers it once
-- the server's configure event arrives. So after the resizing step, later owner
-- boundaries wait for events — returning as soon as one arrives — until the
-- callback has run and its fault is rethrown, within a bound of 'deliveryAttempts'
-- boundaries of at most 'deliveryWaitSeconds' each.
callbackFault ∷ IO String
callbackFault = do
  let faulting =
        productionNative
          { nativeNewWindowCallbacks = \callbacks →
              nativeNewWindowCallbacks
                productionNative
                callbacks
                  { onWindowSize = \_ height →
                      onWindowSize callbacks (throw (ErrorCall "injected size callback fault")) height
                  }
          }
  withScoped (allocComposite (sessionAssembly faulting defaultSessionConfig)) $ \session →
    withWindow session (hiddenTestWindowConfig "faulting" 200 150) $ \window → do
      let resize =
            windowStep window (operation "resize for check") $ \handle → do
              setWindowSizeForCheck handle 260 190
              pollEventsForCheck
          deliver attempt step = do
            outcome ← try step
            case outcome of
              Right (WindowAvailable ())
                | attempt < deliveryAttempts →
                    deliver (attempt + 1) $
                      windowStep window (operation "deliver events for check") (\_ → waitEventsForCheck deliveryWaitSeconds)
              _ → pure (attempt, outcome)
      (boundaries, outcome) ← deliver (0 ∷ Int) resize
      caught ←
        either
          pure
          (\result → failCheck ("after " <> show (boundaries + 1) <> " boundaries the last completed with " <> show result))
          outcome
      case fromException caught of
        Just (ErrorCall message) → do
          let contexts =
                [ (operationText (contextOperation context), contextIdentifiers context)
                | context ← failureContexts (failureEvidence caught)
                ]
          unless (any ((== "window callback") . fst) contexts) $
            failCheck ("the fault carries no callback context: " <> show contexts)
          after ← synchronizeWindow window
          case after of
            WindowAvailable _ → pure ()
            WindowEnded _ → failCheck "the window ended after a contained fault"
          pure ("rethrown " <> show message <> " at boundary " <> show (boundaries + 1) <> " with " <> show contexts)
        Nothing → failCheck ("unexpected failure: " <> displayException caught)

-- | A production table tracing the session's teardown: whether the callback GLFW
-- holds is the monitor callback's own storage when it is detached, whether GLFW
-- holds none afterwards, and where termination, the error callback's detach,
-- and the monitor callback's free fall around it.
monitorTeardown ∷ IO String
monitorTeardown = do
  trace ← newIORef []
  storage ← newIORef Nothing
  let note event = modifyIORef' trace (<> [event])
      monitors = nativeMonitor productionNative
      traced =
        productionNative
          { nativeTerminate = note "terminate" >> nativeTerminate productionNative
          , nativeDetachErrorCallback = note "detach error callback" >> nativeDetachErrorCallback productionNative
          , nativeMonitor =
              monitors
                { nativeNewMonitorCallback = \callback → do
                    allocated ← nativeNewMonitorCallback monitors callback
                    writeIORef storage (Just allocated)
                    pure allocated
                , nativeDetachMonitorCallback = do
                    installed ← installedMonitorCallbackForCheck
                    allocated ← readIORef storage
                    note (if Just installed == allocated then "detach installed callback" else "detach another callback")
                    nativeDetachMonitorCallback monitors
                    remaining ← installedMonitorCallbackForCheck
                    note (if remaining == MonitorCallbackStorage nullFunPtr then "none installed" else "still installed")
                , nativeFreeMonitorCallback = \allocated → note "free monitor callback" >> nativeFreeMonitorCallback monitors allocated
                }
          }
  (reader, count) ←
    withScoped (allocComposite (sessionAssembly traced defaultSessionConfig)) $ \session → do
      inventory ← synchronizeMonitors session
      pure (monitorInventory session, either (const 0) length (monitorList inventory))
  closed ← preparedValue . observedValue <$> atomically (readSnapshot reader)
  traced' ← readIORef trace
  let expected = ["detach installed callback", "none installed", "terminate", "detach error callback", "free monitor callback"]
  unless (traced' == expected) $ failCheck ("the teardown ran " <> show traced')
  unless (inventoryPhase closed == InventoryClosed) $ failCheck ("the inventory was left " <> show (inventoryPhase closed))
  pure (show count <> " monitor(s); teardown " <> intercalate' traced' <> "; closed at revision " <> show (inventoryRevision closed))
  where
    monitorList inventory = case inventoryMonitors inventory of
      Observed descriptions → Right descriptions
      Unavailable → Left ()
    intercalate' = foldr1 (\event rest → event <> ", " <> rest)

-- | Carry every identity from one real session into the next.
monitorAcrossSessions ∷ IO String
monitorAcrossSessions = do
  earlier ← withSession defaultSessionConfig (fmap identitiesOf . synchronizeMonitors)
  when (null earlier) $ failCheck "the first session enumerated no monitor to carry into the next"
  (later, resolved) ←
    withSession defaultSessionConfig $ \session →
      (,) <$> (identitiesOf <$> synchronizeMonitors session) <*> mapM (resolveMonitor session) earlier
  unless (resolved == map MonitorDisconnected earlier) $
    failCheck ("an earlier session's identity resolved: " <> show resolved)
  pure ("identities " <> show earlier <> " answered disconnected in a session enumerating " <> show later)
  where
    identitiesOf inventory = case inventoryMonitors inventory of
      Observed descriptions → map monitorIdentity descriptions
      Unavailable → []

-- | Request a backend this platform's GLFW was not built with, past the model's
-- own refusal, so that GLFW's initialization itself fails and reports why.
initializationError ∷ IO String
initializationError = do
  let unavailable = if hostBackend == Cocoa then X11 else Cocoa
      forced =
        productionNative
          { nativeHostBackend = Just unavailable
          , nativePlatformSupported = \_ → pure True
          }
  outcome ← try (withScoped (allocComposite (sessionAssembly forced defaultSessionConfig)) (\_ → pure ()))
  caught ← either pure (\() → failCheck "initialization succeeded") outcome
  failure ← maybe (failCheck ("unexpected failure: " <> displayException caught)) pure (fromException caught)
  when (nativeOutcome failure /= NativeCallFailed) $
    failCheck ("initialization reported " <> show (nativeOutcome failure))
  let unavailableCode = fromIntegral glfwPlatformUnavailable
      reported = reportedErrors (nativeReports failure)
      matching =
        [ entry
        | entry ← reported
        , nativeErrorCode entry == unavailableCode
        , nativeErrorThread entry == ProcessMainThread
        ]
  when (null matching) $
    failCheck ("no GLFW_PLATFORM_UNAVAILABLE report on the main thread: " <> show reported)
  case failureCause (failureEvidence caught) of
    EngineOrigin origin → do
      let component = componentText (originComponent origin)
          operationName = operationText (originOperation origin)
      unless (component == "glfw" && operationName == "initialize") $
        failCheck ("attributed to " <> Text.unpack component <> " " <> Text.unpack operationName)
      pure
        ( "glfw initialize failed before polling: "
            <> concatMap (Text.unpack . nativeErrorDescription) matching
        )
    NativeCause → failCheck "the failure carries no engine origin"

-- | How many owner boundaries may wait for a callback the platform has yet to
-- deliver, and the most each waits for an event.
deliveryAttempts ∷ Int
deliveryAttempts = 100

deliveryWaitSeconds ∷ Double
deliveryWaitSeconds = 0.05

failCheck ∷ String → IO a
failCheck = ioError . userError
