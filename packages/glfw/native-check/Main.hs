-- | The native GLFW session check.
--
-- It exercises the real session against the installed GLFW on the platform
-- it runs on: entering and leaving a session, a sequential session after a
-- complete teardown, duplicate and wrong-thread entry, owner-only use from
-- another thread, a hidden NoAPI window through the creation seam, and an
-- initialization error observed before any event polling exists.
--
-- GLFW requires the process main thread, and Hspec runs its examples on
-- threads of its own, so this is a plain executable whose checks run in order
-- on the thread that entered @main@. The shared native Hspec fixture with a
-- main-thread dispatcher is later work. It needs a windowing session, so it is
-- not part of @hetoimasia-tests@, the console smoke, or any validation group;
-- @cabal build all@ compiles it without running it.
--
-- Each check prints one line. The run fails if any check fails.
module Main (main) where

import Control.Concurrent (ThreadId, forkIO, forkOS)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Exception (Exception, SomeException, displayException, fromException, try)
import Control.Monad (unless, when)
import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import qualified Data.Text as Text
import Foreign.Ptr (nullPtr)
import Hetoimasia.Foundation.Failure
  ( FailureCause (..)
  , FailureEvidence (..)
  , FailureOrigin (..)
  , failureEvidence
  , operationText
  )
import Hetoimasia.Foundation.Log (componentText)
import Hetoimasia.Foundation.Resource (allocComposite, withComposite, withScoped)
import Hetoimasia.GLFW.Internal.Native (glfwPlatformUnavailable, productionNative)
import Hetoimasia.GLFW.Internal.Session
  ( Native (..)
  , WindowRequest (..)
  , WindowVisibility (..)
  , nativeWindowAssembly
  , sessionAssembly
  )
import Hetoimasia.GLFW.Session
import System.Exit (exitFailure)
import System.IO (hFlush, stdout)
import System.Info (os)

main ∷ IO ()
main = do
  failures ← newIORef (0 ∷ Int)
  mapM_ (runCheck failures) checks
  failed ← readIORef failures
  if failed == 0
    then putStrLn "glfw-native-check: every check passed"
    else do
      putStrLn ("glfw-native-check: " <> show failed <> " check(s) failed")
      exitFailure

runCheck ∷ IORef Int → (String, IO String) → IO ()
runCheck failures (name, check) = do
  outcome ← try check
  case outcome of
    Right detail → putStrLn ("ok   " <> name <> ": " <> detail)
    Left (failure ∷ SomeException) → do
      modifyIORef' failures (+ 1)
      putStrLn ("FAIL " <> name <> ": " <> displayException failure)
  hFlush stdout

checks ∷ [(String, IO String)]
checks =
  [ ("enters and leaves a real session", enterAndLeave)
  , ("enters a second session after a complete teardown", enterAndLeave)
  , ("rejects a nested entry from the owner thread", nestedEntry)
  , ("rejects entry from a bound worker thread", workerEntry forkOS)
  , ("rejects entry from an unbound thread", workerEntry forkIO)
  , ("rejects owner-only use from another thread", ownerOnlyElsewhere)
  , ("creates and destroys a hidden NoAPI window", hiddenWindow)
  , ("observes an initialization error before any event polling", initializationError)
  , ("enters a session after the failed initialization rolled back", enterAndLeave)
  ]

hostBackend ∷ Backend
hostBackend = if os == "darwin" then Cocoa else X11

enterAndLeave ∷ IO String
enterAndLeave = do
  (backend, reports) ← withSession defaultSessionConfig $ \session → do
    reports ← takeAsynchronousReports session
    pure (sessionBackend session, reports)
  unless (backend == hostBackend) $
    failCheck ("the session selected " <> show backend <> ", not " <> show hostBackend)
  pure ("backend " <> show backend <> ", asynchronous reports " <> show reports)

nestedEntry ∷ IO String
nestedEntry =
  withSession defaultSessionConfig $ \_ → do
    misuse ← expectFailure (withSession defaultSessionConfig (\_ → pure ()))
    unless (misuse == SessionAlreadyActive) $ failCheck ("rejected with " <> show misuse)
    pure (show misuse)

workerEntry ∷ (IO () → IO ThreadId) → IO String
workerEntry fork = do
  misuse ← onThread fork (expectFailure (withSession defaultSessionConfig (\_ → pure ())))
  unless (misuse == NotProcessMainThread) $ failCheck ("rejected with " <> show misuse)
  pure (show misuse)

ownerOnlyElsewhere ∷ IO String
ownerOnlyElsewhere =
  withSession defaultSessionConfig $ \session → do
    misuse ← onThread forkOS (expectFailure (takeAsynchronousReports session))
    unless (misuse == NotSessionOwner) $ failCheck ("rejected with " <> show misuse)
    pure (show misuse)

hiddenWindow ∷ IO String
hiddenWindow =
  withSession defaultSessionConfig $ \session → do
    let request =
          WindowRequest
            { windowWidth = 320
            , windowHeight = 240
            , windowTitle = "hetoimasia native check"
            , windowVisibility = HiddenTestWindow
            }
    created ← withComposite (nativeWindowAssembly session request) (\window → pure (window /= nullPtr))
    unless created $ failCheck "the creation seam lent a null window"
    reports ← takeAsynchronousReports session
    pure ("hidden window created and destroyed, asynchronous reports " <> show reports)

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

expectFailure ∷ Exception e ⇒ IO a → IO e
expectFailure action = do
  outcome ← try action
  case outcome of
    Right _ → failCheck "expected a rejection, but the action returned"
    Left caught →
      maybe
        (failCheck ("unexpected failure: " <> displayException (caught ∷ SomeException)))
        pure
        (fromException caught)

onThread ∷ (IO () → IO ThreadId) → IO a → IO a
onThread fork action = do
  finished ← newEmptyMVar
  _ ← fork (try action >>= putMVar finished)
  outcome ← takeMVar finished
  either (\failure → failCheck (displayException (failure ∷ SomeException))) pure outcome

failCheck ∷ String → IO a
failCheck = ioError . userError
