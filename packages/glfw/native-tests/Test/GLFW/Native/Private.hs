-- | Session lifecycles no shared session can host.
--
-- GLFW allows one session per process, and the shared fixture holds that one
-- for the whole run, so entering and leaving sessions in sequence, a forced
-- initialization failure and its rollback, and a session over a faulting native
-- table each need a process of their own. Each example here starts this same
-- executable as a child with 'privateSessionFlag' and a scenario name; the
-- child runs that scenario's checks in order on its own process main thread,
-- prints one line per check, and exits non-zero if any failed. A dry run or a
-- selection that skips these examples starts no child.
module Test.GLFW.Native.Private
  ( spec
  , privateSessionFlag
  , runScenario
  ) where

import Control.Exception (ErrorCall (ErrorCall), SomeException, displayException, fromException, throw, try)
import Control.Monad (unless, when)
import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
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
import Hetoimasia.Foundation.Resource (allocComposite, withScoped)
import Hetoimasia.GLFW.Internal.Native
  ( glfwPlatformUnavailable
  , pollEventsForCheck
  , productionNative
  , setWindowSizeForCheck
  )
import Hetoimasia.GLFW.Internal.Session (Native (..), WindowCallbacks (..), sessionAssembly)
import Hetoimasia.GLFW.Internal.Window (windowStep)
import Hetoimasia.GLFW.Session
import Hetoimasia.GLFW.Window
import System.Environment (getExecutablePath)
import System.Exit (ExitCode (..), exitFailure, exitWith)
import System.IO (hFlush, hPutStrLn, stderr, stdout)
import System.Process (readProcessWithExitCode)
import Test.GLFW.Native.Support (hostBackend)
import Test.Hspec (Spec, describe, expectationFailure, it, shouldContain)

-- | The argument that makes this executable a private-session child.
privateSessionFlag ∷ String
privateSessionFlag = "--private-session"

spec ∷ Spec
spec = describe "private sessions in a child process" $ do
  it "enters and leaves real sessions in sequence, fails a forced initialization, and enters again after its rollback" $
    privateScenario "session-lifecycle"

  it "rethrows a fault raised inside a real native callback at the owner boundary" $
    privateScenario "callback-fault"

privateScenario ∷ String → IO ()
privateScenario name = do
  executable ← getExecutablePath
  (status, out, err) ← readProcessWithExitCode executable [privateSessionFlag, name] ""
  unless (status == ExitSuccess) $
    expectationFailure ("the private " <> name <> " process exited " <> show status <> ":\n" <> out <> err)
  out `shouldContain` ("glfw-native-tests " <> name <> ": every check passed")

-- | Run one scenario as the child process, then exit.
runScenario ∷ String → IO ()
runScenario name = case lookup name scenarios of
  Nothing → do
    hPutStrLn stderr ("glfw-native-tests: unknown private session scenario " <> show name)
    exitWith (ExitFailure 2)
  Just checks → do
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
      outcome ←
        try $
          windowStep window (operation "resize for check") $ \handle → do
            setWindowSizeForCheck handle 260 190
            pollEventsForCheck
      caught ← either pure (\result → failCheck ("the boundary completed with " <> show result)) outcome
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
          pure ("rethrown " <> show message <> " with " <> show contexts)
        Nothing → failCheck ("unexpected failure: " <> displayException caught)

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

failCheck ∷ String → IO a
failCheck = ioError . userError
