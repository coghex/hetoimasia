-- | The native GLFW session check.
--
-- It exercises the real session against the installed GLFW on the platform
-- it runs on: entering and leaving a session, a sequential session after a
-- complete teardown, duplicate and wrong-thread entry, owner-only use from
-- another thread, hidden non-focusing NoAPI windows — their creation,
-- observation, and release, hint isolation between two live windows, a session
-- surviving a window's release, and a terminal handle — a fault raised inside a
-- real native callback, and an initialization error observed before any event
-- polling exists.
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
import Control.Concurrent.STM (atomically)
import Control.Exception (ErrorCall (ErrorCall), Exception, SomeException, displayException, fromException, throw, try)
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
import Hetoimasia.Foundation.Messaging.Payload (preparedValue)
import Hetoimasia.Foundation.Messaging.Snapshot (observedValue, readSnapshot)
import Hetoimasia.Foundation.Resource (allocComposite, withScoped)
import Hetoimasia.GLFW.Internal.Native
  ( glfwPlatformUnavailable
  , leakResizableHintForCheck
  , pollEventsForCheck
  , productionNative
  , setWindowSizeForCheck
  , windowResizableForCheck
  )
import Hetoimasia.GLFW.Internal.Session
  ( Native (..)
  , WindowCallbacks (..)
  , sessionAssembly
  )
import Hetoimasia.GLFW.Internal.Window (windowNativeHandle, windowStep)
import Hetoimasia.GLFW.Session
import Hetoimasia.GLFW.Window
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
  , ("creates, observes, and releases a hidden non-focusing window", hiddenWindow)
  , ("resets creation hints between two live windows", hintIsolation)
  , ("creates another window after a window's release", recreateWindow)
  , ("rethrows a fault raised inside a real native callback at the owner boundary", callbackFault)
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
hiddenWindow = do
  (initial, synchronized, afterEnd, final, ended, identity) ←
    withSession defaultSessionConfig $ \session → do
      (initial, synchronized, window) ←
        withWindow session (hiddenTestWindowConfig "hetoimasia native check" 320 240) $ \window → do
          initial ← currentObservation window
          synchronized ← synchronizeWindow window
          pure (initial, synchronized, window)
      -- Deliberate misuse: the handle escaped its scope to prove it is terminal.
      afterEnd ← synchronizeWindow window
      final ← currentObservation window
      ended ← windowEnded window
      pure (initial, synchronized, afterEnd, final, ended, windowIdentity window)
  case observedFramebufferExtent initial of
    Observed (Extent width height) | width > 0 && height > 0 → pure ()
    other → failCheck ("the initial framebuffer observation is " <> show other)
  unless (observedPhase initial == WindowOpen && observedVisible initial == Observed False) $
    failCheck ("the initial observation is " <> show initial)
  case synchronized of
    WindowAvailable _ → pure ()
    WindowEnded _ → failCheck "a live window answered as ended"
  unless (afterEnd == WindowEnded identity && ended) $
    failCheck ("after its scope the handle answered " <> show afterEnd)
  unless (observedPhase final == WindowReleased) $
    failCheck ("the terminal observation is " <> show final)
  pure
    ( "logical "
        <> show (observedLogicalExtent initial)
        <> ", framebuffer "
        <> show (observedFramebufferExtent initial)
        <> ", scale "
        <> show (observedContentScale initial)
        <> ", placement "
        <> show (observedPlacement initial)
        <> "; terminal "
        <> show (observedPhase final)
        <> " at revision "
        <> show (observedRevision final)
        <> ", then "
        <> show afterEnd
    )

hintIsolation ∷ IO String
hintIsolation =
  withSession defaultSessionConfig $ \session →
    withWindow session (hiddenTestWindowConfig "first" 200 150) $ \first → do
      leakResizableHintForCheck
      withWindow session (hiddenTestWindowConfig "second" 220 160) $ \second → do
        resizable ← windowResizableForCheck (windowNativeHandle second)
        unless resizable $ failCheck "the second window inherited a stray GLFW_RESIZABLE hint"
        firstObserved ← currentObservation first
        secondObserved ← currentObservation second
        unless (all ((== Observed False) . observedVisible) [firstObserved, secondObserved]) $
          failCheck "a hidden window was observed visible"
        when (windowIdentity first == windowIdentity second) $
          failCheck "two live windows share an identity"
        pure
          ( show (windowIdentity first)
              <> " and "
              <> show (windowIdentity second)
              <> " live and hidden; a stray hint was reset before the second"
          )

recreateWindow ∷ IO String
recreateWindow =
  withSession defaultSessionConfig $ \session → do
    released ← withWindow session (hiddenTestWindowConfig "released" 160 120) (pure . windowIdentity)
    recreated ← withWindow session (hiddenTestWindowConfig "recreated" 160 120) (pure . windowIdentity)
    when (released == recreated) $ failCheck "the recreated window reused an identity"
    reports ← takeAsynchronousReports session
    pure (show released <> " released, then " <> show recreated <> "; asynchronous reports " <> show reports)

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

currentObservation ∷ Window → IO WindowObservation
currentObservation window =
  preparedValue . observedValue <$> atomically (readSnapshot (windowObservations window))

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
