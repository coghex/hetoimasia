-- | The private-session scenarios the Wayland evidence runs in child processes.
--
-- Each is a list of checks "Test.GLFW.Native.Private" runs in a child of its
-- own, because each needs a session the shared fixture cannot host: one entered
-- in an environment it must not reach, one over a traced native table, or one
-- whose compositor the child deliberately ends. They are written for the
-- isolated Wayland consent @tools/display/wayland.sh@ supplies, except
-- @wayland-without-compositor@, which runs under @tools/display/x11.sh@.
--
-- = The connection-loss children
--
-- A connection-loss child never touches the compositor its consent names. It
-- starts a compositor of its own ('withPrivateCompositor'): packaged Weston,
-- headless, on a socket of its own in a runtime directory created for it with
-- mode 0700, with no configuration file, and with @WAYLAND_DISPLAY@,
-- @WAYLAND_SOCKET@, and @DISPLAY@ removed from its environment. Readiness is a
-- connection — @wayland-info@ connecting to that socket, bounded — never an
-- elapsed time. The child's own sessions then reach that compositor alone,
-- through @WAYLAND_DISPLAY@ set to the socket's absolute path. Ending it is
-- @SIGTERM@ and a bounded wait for its exit, so the socket is closed before the
-- next event processing; the compositor is ended on every exit path, and its
-- directory removed. It runs in the child's process group, so the parent's
-- deadline ends it too if the child hangs.
--
-- The four situations are the Wayland qualification design's D-12 connection
-- loss case. The loss situations assert the probe's own verdict — the failure,
-- its cause, its boundary, and that the session is then terminal, raising the
-- same failure with no probe and no pump — never a close-request pattern. The
-- close requests they need are /injected/ through the window's own close
-- callback ('injectCloseForCheck') and labelled so: no client can make the
-- compositor generate one, and none of this is evidence that one was. The
-- healthy control keeps its compositor running throughout. What a session's
-- teardown reports after its compositor is gone is recorded, not asserted.
module Test.GLFW.Native.WaylandScenarios (scenarios) where

import Control.Concurrent (forkIO, threadDelay, yield)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Concurrent.STM (TVar, atomically, check, newTVarIO, orElse, readTVar, readTVarIO, registerDelay, retry, writeTVar)
import Control.Exception (Exception (..), ExceptionWithContext (ExceptionWithContext), SomeException, bracket, finally, throwIO, try)
import Control.Monad (forM_, unless, when)
import Data.IORef (IORef, atomicModifyIORef', modifyIORef', newIORef, readIORef, writeIORef)
import Data.List (find)
import Data.Maybe (isJust)
import qualified Data.Text as Text
import GHC.Clock (getMonotonicTime)
import Hetoimasia.Foundation.Failure
  ( FailureCause (..)
  , FailureOrigin (..)
  , failureCause
  , failureEvidence
  , operationText
  )
import Hetoimasia.Foundation.Log (componentText)
import Hetoimasia.Foundation.Resource
  ( allocComposite
  , cleanupFailureException
  , cleanupFailures
  , withScoped
  )
import Hetoimasia.GLFW.Command
  ( Disposition (..)
  , UnsupportedControl (..)
  , newWindowCommandHost
  , performWindowCommand
  , requestFocusCommand
  , setWindowModeCommand
  , setWindowPositionCommand
  )
import Hetoimasia.GLFW.Internal.Connection (ConnectionProbe (..), ConnectionStatus (..))
import Hetoimasia.GLFW.Internal.Native
  ( blockedWaitForCheck
  , glfwPlatformUnavailable
  , injectCloseForCheck
  , productionNative
  , takeInputCallbacksClearedForCheck
  , takeLastWaitForCheck
  )
import Hetoimasia.GLFW.Internal.Session (Native (..), WindowAttribute (IconifiedAttribute), sessionAssembly)
import Hetoimasia.GLFW.Internal.Window (EventProcessing (..), processWindowEvents, rejectCloseRequest, windowNativeHandle)
import Hetoimasia.GLFW.Mode (borderlessMode, modeRequest, noModeFallback)
import Hetoimasia.GLFW.Monitor
import Hetoimasia.GLFW.Session
import Hetoimasia.GLFW.Window
import System.Directory (getTemporaryDirectory, removeDirectoryRecursive)
import System.Environment (getEnvironment, lookupEnv, setEnv, unsetEnv)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO (IOMode (WriteMode), openFile)
import System.Posix.Process (getProcessID)
import System.Posix.Temp (mkdtemp)
import Numeric.Natural (Natural)
import System.Process
  ( CreateProcess (env, std_err, std_in, std_out)
  , ProcessHandle
  , StdStream (NoStream, UseHandle)
  , createProcess
  , getProcessExitCode
  , proc
  , terminateProcess
  , waitForProcess
  )
import Test.GLFW.Native.Child (ChildEnd (..), Launched (..), launchCommandIn)
import Test.GLFW.Native.Consent (Consent)
import Test.GLFW.Native.Support (consentBackend, consentSessionConfig)

-- | The Wayland scenarios, for a child running under this consent.
scenarios ∷ Consent → [(String, [(String, IO String)])]
scenarios consent =
  [ ( "wayland-default-x11"
    , [ ( "a session requesting nothing still selects X11, and with no X11 display reachable GLFW's initialization fails for that reason"
        , defaultWithoutX11
        )
      ]
    )
  , ( "wayland-without-compositor"
    , [ ( "a session requesting Wayland in an X11-only environment fails GLFW's initialization for lack of a Wayland connection"
        , waylandWithoutCompositor
        )
      ]
    )
  , ( "wayland-unsupported"
    , [ ( "answers placement, focus, and borderless requests unsupported and placement and iconified observations unavailable, invoking none of their native operations or getters"
        , unsupportedOutcomes
        )
      ]
    )
  , ( "wayland-failure-cleanup"
    , [ ( "keeps a forced initialization failure primary, leaves no registration behind, and enters a later session"
        , forcedInitialization consent
        )
      , ( "keeps an injected window-construction failure primary beside an injected cleanup failure, releases the real window and its callbacks, and creates a later window"
        , injectedConstruction consent
        )
      ]
    )
  , ( "connection-loss-pending-close"
    , [("confirms the loss while rejected close requests are pending, and the session is terminal", lossWithPendingCloseRequests)]
    )
  , ( "connection-loss-no-windows"
    , [("confirms the loss of a session with no window, and the session is terminal", lossWithoutWindows)]
    )
  , ( "connection-loss-in-wait"
    , [("confirms a loss that happens while the owner is inside a native wait, and the session is terminal", lossInsideWait)]
    )
  , ( "connection-healthy-close"
    , [("does not mistake an injected close request on a healthy connection for loss, and the session stays live", healthyCloseRequest)]
    )
  ]

-- ---------------------------------------------------------------------------
-- Backend selection

-- | Under the isolated compositor no X11 display exists, so the platform's own
-- default fails at GLFW's initialization — the display, not a missing request.
defaultWithoutX11 ∷ IO String
defaultWithoutX11 = do
  display ← lookupEnv "DISPLAY"
  when (isJust display) $
    failCheck ("DISPLAY is " <> show display <> "; this check needs an environment with no X11 display")
  outcome ← try (withSession defaultSessionConfig (pure . sessionBackend))
  caught ← either pure (\backend → failCheck ("a session requesting nothing entered " <> show backend)) outcome
  case fromException caught of
    Just refused@UnsupportedBackend {} → failCheck ("refused as unsupported rather than for the missing display: " <> show refused)
    Nothing → pure ()
  failure ← maybe (failCheck ("unexpected failure: " <> displayException caught)) pure (fromException caught)
  requireOrigin caught "initialize" "x11"
  unless (nativeOutcome failure == NativeCallFailed) $
    failCheck ("initialization reported " <> show (nativeOutcome failure))
  let missing =
        [ nativeErrorDescription entry
        | entry ← reportedErrors (nativeReports failure)
        , nativeErrorCode entry == platformUnavailableCode
        , "DISPLAY" `Text.isInfixOf` nativeErrorDescription entry
        ]
  when (null missing) $
    failCheck ("no GLFW_PLATFORM_UNAVAILABLE report naming DISPLAY: " <> show (reportedErrors (nativeReports failure)))
  pure ("an unrequested session was resolved to X11 and glfw initialize failed: " <> Text.unpack (Text.intercalate "; " missing))

-- | Under @tools/display/x11.sh@ an X11 display exists and no Wayland socket
-- does. The runtime directory is pointed at an empty one of this child's own,
-- so no compositor the machine happens to run can answer either.
waylandWithoutCompositor ∷ IO String
waylandWithoutCompositor = do
  display ← lookupEnv "DISPLAY"
  wayland ← lookupEnv "WAYLAND_DISPLAY"
  unless (maybe False (not . null) display) $ failCheck "DISPLAY is not set; this check runs under the isolated X11 helper"
  when (isJust wayland) $ failCheck ("WAYLAND_DISPLAY is " <> show wayland <> "; this check needs an X11-only environment")
  withPrivateDirectory "hetoimasia-no-wayland." $ \empty → do
    setEnv "XDG_RUNTIME_DIR" empty
    unsetEnv "WAYLAND_SOCKET"
    outcome ← try (withSession waylandConfig (pure . sessionBackend))
    caught ← either pure (\backend → failCheck ("a Wayland request entered " <> show backend)) outcome
    failure ← maybe (failCheck ("unexpected failure: " <> displayException caught)) pure (fromException caught)
    requireOrigin caught "initialize" "wayland"
    let unreachable =
          [ nativeErrorDescription entry
          | entry ← reportedErrors (nativeReports failure)
          , nativeErrorCode entry == nativePlatformError productionNative
          , "connect" `Text.isInfixOf` nativeErrorDescription entry
          ]
    when (null unreachable) $
      failCheck ("no GLFW_PLATFORM_ERROR report of a failed Wayland connection: " <> show (reportedErrors (nativeReports failure)))
    pure
      ( "with X11 display "
          <> maybe "" id display
          <> " reachable and no Wayland socket, a Wayland request failed glfw initialize: "
          <> Text.unpack (Text.intercalate "; " unreachable)
      )

-- ---------------------------------------------------------------------------
-- Unsupported outcomes

-- | A Wayland session over a production table that records every call of the
-- operations and getters the Wayland capability row declares unavailable.
unsupportedOutcomes ∷ IO String
unsupportedOutcomes = do
  invoked ← newIORef ([] ∷ [String])
  let note call = modifyIORef' invoked (<> [call])
      traced =
        productionNative
          { nativeSetWindowPosition = \handle x y → note "glfwSetWindowPos" >> nativeSetWindowPosition productionNative handle x y
          , nativeWindowPosition = \handle → note "glfwGetWindowPos" >> nativeWindowPosition productionNative handle
          , nativeFocusWindow = \handle → note "glfwFocusWindow" >> nativeFocusWindow productionNative handle
          , nativeSetWindowMonitor = \handle monitor x y width height refresh →
              note "glfwSetWindowMonitor" >> nativeSetWindowMonitor productionNative handle monitor x y width height refresh
          , nativeWindowAttribute = \handle attribute → do
              when (attribute == IconifiedAttribute) (note "glfwGetWindowAttrib(GLFW_ICONIFIED)")
              nativeWindowAttribute productionNative handle attribute
          }
  (outcomes, placement, iconified) ←
    withScoped (allocComposite (sessionAssembly traced waylandConfig)) $ \session → do
      requireWayland session
      monitor ← selectedMonitor session
      withWindow session (hiddenTestWindowConfig "unsupported controls" 200 150) $ \window → do
        host ← newWindowCommandHost session 8
        let target = windowIdentity window
            perform = performWindowCommand host [window]
        moved ← perform (setWindowPositionCommand target (Placement 120 90))
        focused ← perform (requestFocusCommand target)
        borderless ← perform (setWindowModeCommand target (modeRequest (borderlessMode (monitorIdentity monitor)) noModeFallback))
        observation ← synchronized window
        pure ([moved, focused, borderless], observedPlacement observation, observedIconified observation)
  made ← readIORef invoked
  let expected = [SetPositionOperation, FocusOperation, BorderlessOperation]
      answered =
        [ (operation, reason)
        | Unsupported (UnsupportedControl _ operation reason) ← outcomes
        ]
  unless (map fst answered == expected && all (not . Text.null . snd) answered) $
    failCheck ("the requests settled as " <> show outcomes)
  unless (placement == Unavailable && iconified == Unavailable) $
    failCheck ("the observation reported placement " <> show placement <> " and iconified " <> show iconified)
  unless (null made) $
    failCheck ("the model invoked native operations the Wayland row declares unavailable: " <> show made)
  pure
    ( "unsupported with reasons "
        <> show answered
        <> "; placement and iconified observations Unavailable; no native call among glfwSetWindowPos, glfwGetWindowPos, glfwFocusWindow, glfwSetWindowMonitor, or glfwGetWindowAttrib(GLFW_ICONIFIED)"
    )

-- ---------------------------------------------------------------------------
-- Failure cleanup

-- | An injected failure, labelled so wherever it is reported.
newtype Injected = Injected String
  deriving (Eq, Show)

instance Exception Injected where
  displayException (Injected what) = "injected failure: " <> what

-- | Injected: a request for Cocoa, which this Linux prefix lacks, forced past
-- the model's own refusal so that GLFW's initialization itself fails. Its
-- rollback must keep that failure primary with no cleanup failure, free every
-- error callback storage it allocated, and vacate the guard, which a later
-- session's entry proves.
forcedInitialization ∷ Consent → IO String
forcedInitialization consent = do
  storages ← newIORef (0 ∷ Int, 0 ∷ Int)
  let forced =
        productionNative
          { nativeHostBackend = Just Cocoa
          , nativeAdmittedBackends = [Cocoa]
          , nativePlatformSupported = \_ → pure True
          , nativeNewErrorCallback = \callback → do
              modifyIORef' storages (\(made, freed) → (made + 1, freed))
              nativeNewErrorCallback productionNative callback
          , nativeFreeErrorCallback = \storage → do
              modifyIORef' storages (\(made, freed) → (made, freed + 1))
              nativeFreeErrorCallback productionNative storage
          }
  outcome ← try (withScoped (allocComposite (sessionAssembly forced defaultSessionConfig)) (\_ → pure ()))
  caught ← either pure (\() → failCheck "the forced initialization succeeded") outcome
  failure ← maybe (failCheck ("unexpected failure: " <> displayException caught)) pure (fromException caught)
  requireOrigin caught "initialize" "cocoa"
  unless (nativeOutcome failure == NativeCallFailed) $
    failCheck ("initialization reported " <> show (nativeOutcome failure))
  unless (null (cleanupFailures caught)) $
    failCheck ("the rollback retained cleanup failures: " <> show (map (displayException . cleanupFailureException) (cleanupFailures caught)))
  (made, freed) ← readIORef storages
  unless (made == 1 && freed == 1) $
    failCheck ("the rollback allocated " <> show made <> " error callback storage(s) and freed " <> show freed)
  later ← withSession (consentSessionConfig consent) (pure . sessionBackend)
  unless (later == consentBackend consent) $
    failCheck ("the later session selected " <> show later)
  pure
    ( "injected: a Cocoa request forced past the model's refusal failed glfw initialize with "
        <> show (map nativeErrorDescription (reportedErrors (nativeReports failure)))
        <> "; the rollback retained no cleanup failure and freed "
        <> show freed
        <> " of "
        <> show made
        <> " error callback storage; a later session entered "
        <> show later
    )

-- | Injected: the first window's initial sample fails after the real window
-- exists and its callbacks are attached, and releasing its callback storage
-- then fails after the storage was really freed. The construction's failure
-- stays primary with the release's failure retained beside it; the rollback
-- detaches every input callback before it destroys the one real window and
-- frees the one storage; and the session, unpoisoned, creates a later window.
injectedConstruction ∷ Consent → IO String
injectedConstruction consent = do
  sampleArmed ← newIORef True
  releaseArmed ← newIORef True
  counts ← newIORef (0 ∷ Int, 0 ∷ Int, 0 ∷ Int, 0 ∷ Int)
  let bump update = modifyIORef' counts update
      fire armed = atomicModifyIORef' armed (\firing → (False, firing))
      traced =
        productionNative
          { nativeCreateWindow = \width height title → do
              bump (\(c, d, n, f) → (c + 1, d, n, f))
              nativeCreateWindow productionNative width height title
          , nativeDestroyWindow = \handle → do
              bump (\(c, d, n, f) → (c, d + 1, n, f))
              nativeDestroyWindow productionNative handle
          , nativeNewWindowCallbacks = \callbacks → do
              bump (\(c, d, n, f) → (c, d, n + 1, f))
              nativeNewWindowCallbacks productionNative callbacks
          , nativeFreeWindowCallbacks = \storage → do
              bump (\(c, d, n, f) → (c, d, n, f + 1))
              nativeFreeWindowCallbacks productionNative storage
              firing ← fire releaseArmed
              when firing (throwIO (Injected "releasing the window's callback storage, after it was freed"))
          , nativeWindowSize = \handle → do
              firing ← fire sampleArmed
              when firing (throwIO (Injected "sampling the constructed window"))
              nativeWindowSize productionNative handle
          }
  (primary, retained, cleared, afterFailure, later, final) ←
    withScoped (allocComposite (sessionAssembly traced (consentSessionConfig consent))) $ \session → do
      outcome ← try (withWindow session (hiddenTestWindowConfig "injected construction" 120 90) (\_ → pure ()))
      caught ← either pure (\() → failCheck "the injected construction succeeded") outcome
      cleared ← takeInputCallbacksClearedForCheck
      afterFailure ← readIORef counts
      later ← withWindow session (hiddenTestWindowConfig "after the injected failure" 120 90) synchronizeWindow
      final ← readIORef counts
      pure
        ( fromException caught
        , map (fromException . cleanupException) (cleanupFailures caught)
        , cleared
        , afterFailure
        , later
        , final
        )
  unless (primary == Just (Injected "sampling the constructed window")) $
    failCheck ("the primary failure was " <> show primary)
  unless (retained == [Just (Injected "releasing the window's callback storage, after it was freed")]) $
    failCheck ("the retained cleanup failures were " <> show retained)
  unless cleared $ failCheck "the window was destroyed with an input callback still registered"
  unless (afterFailure == (1, 1, 1, 1)) $
    failCheck ("after the failure: (created, destroyed, storages allocated, storages freed) = " <> show afterFailure)
  case later of
    WindowAvailable _ → pure ()
    WindowEnded _ → failCheck "the later window answered as ended"
  unless (final == (2, 2, 2, 2)) $
    failCheck ("after the later window: (created, destroyed, storages allocated, storages freed) = " <> show final)
  pure
    ( "injected construction failure primary, injected release failure retained beside it; the rollback cleared every input callback before destroying 1 of 1 real window and freed 1 of 1 callback storage; a later window was created and released, "
        <> show final
        <> " in all"
    )
  where
    cleanupException failure = case cleanupFailureException failure of
      ExceptionWithContext _ thrown → thrown

-- ---------------------------------------------------------------------------
-- Connection loss

-- | Close requests are injected and rejected; a second injected request is
-- left pending; then the compositor is ended, and the next event processing
-- must confirm the loss before it pumps anything.
lossWithPendingCloseRequests ∷ IO String
lossWithPendingCloseRequests =
  withPrivateCompositor $ \compositor → do
    (statuses, pumps, native) ← observedNative
    (evidence, teardown) ←
      lostSession compositor native $ \session →
        withWindow session (hiddenTestWindowConfig "rejecting close requests" 200 150) $ \window → do
          let handle = windowNativeHandle window
          injectCloseForCheck handle
          processWindowEvents session ProcessPending
          first ← closeRequestOf window
          rejected ← rejectCloseRequest window first
          unless (rejected == WindowAvailable True) $ failCheck ("the application's rejection answered " <> show rejected)
          injectCloseForCheck handle
          ended ← endCompositor compositor
          (failure, pumpsBefore, pumpsAfter) ← confirmedLoss session pumps ProcessPending
          pending ← observedCloseRequest <$> synchronized window
          mapM_ (rejectCloseRequest window) pending
          terminal ← latched session statuses pumps failure
          seen ← readIORef statuses
          requireLoss failure BeforeEvents
          unless (pumpsAfter == pumpsBefore) $ failCheck "the lost connection was pumped"
          unless (isJust pending) $ failCheck "the injected close request left pending was not there"
          pure (ended, failure, seen, terminal)
    let (ended, failure, seen, terminal) = evidence
    pure
      ( "injected close requests: one rejected, one pending; compositor "
          <> compositorVersion compositor
          <> " ended ("
          <> show ended
          <> "); "
          <> describeLoss failure
          <> "; probe statuses "
          <> show seen
          <> "; "
          <> terminal
          <> "; "
          <> teardown
      )

-- | No window at all: the compositor is ended and the next finite wait must
-- confirm the loss before it waits.
lossWithoutWindows ∷ IO String
lossWithoutWindows =
  withPrivateCompositor $ \compositor → do
    (statuses, pumps, native) ← observedNative
    (evidence, teardown) ←
      lostSession compositor native $ \session → do
        processWindowEvents session ProcessPending
        ended ← endCompositor compositor
        (failure, pumpsBefore, pumpsAfter) ← confirmedLoss session pumps (AwaitEventsFor 5)
        terminal ← latched session statuses pumps failure
        requireLoss failure BeforeEvents
        unless (pumpsAfter == pumpsBefore) $ failCheck "the lost connection was waited on"
        seen ← readIORef statuses
        pure (ended, failure, seen, terminal)
    let (ended, failure, seen, terminal) = evidence
    pure
      ( "no window; compositor "
          <> compositorVersion compositor
          <> " ended ("
          <> show ended
          <> "); "
          <> describeLoss failure
          <> "; probe statuses "
          <> show seen
          <> "; "
          <> terminal
          <> "; "
          <> teardown
      )

-- | The owner enters a long finite wait; a worker ends the compositor only once
-- it has observed that wait blocked inside GLFW. The wait must return before
-- its bound and the probe after it must confirm the loss.
lossInsideWait ∷ IO String
lossInsideWait =
  withPrivateCompositor $ \compositor → do
    (statuses, pumps, native) ← observedNative
    (evidence, teardown) ←
      lostSession compositor native $ \session →
        withWindow session (hiddenTestWindowConfig "waiting" 200 150) $ \window → do
          processWindowEvents session ProcessPending
          (floor', _) ← takeLastWaitForCheck
          ownerDone ← newTVarIO False
          worker ← newEmptyMVar
          _ ← forkIO (try (endWhenBlocked ownerDone floor' compositor) >>= putMVar worker)
          started ← getMonotonicTime
          outcome ← try (processWindowEvents session (AwaitEventsFor lossWaitBound)) `finally` atomically (writeTVar ownerDone True)
          seconds ← subtract started <$> getMonotonicTime
          ended ←
            takeMVar worker >>= \case
              Left thrown → failCheck ("the worker failed: " <> displayException (thrown ∷ SomeException))
              Right Nothing → failCheck "the worker never observed the owner blocked inside GLFW's wait"
              Right (Just (blocked, status)) → pure (blocked, status)
          failure ← case outcome of
            Left thrown → maybe (failCheck ("unexpected failure: " <> displayException (thrown ∷ SomeException))) pure (fromException thrown)
            Right () → failCheck "the wait returned with the connection lost and nothing confirmed it"
          requireLoss failure AfterEvents
          when (seconds >= lossWaitBound) $
            failCheck ("the wait ran to its bound of " <> show lossWaitBound <> " seconds rather than returning on the loss")
          -- GLFW's disconnect path issues a close request to every window; it
          -- is recorded, and rejected as the application rejects every one,
          -- but it is not what confirmed the loss.
          closing ← observedCloseRequest <$> synchronized window
          mapM_ (rejectCloseRequest window) closing
          terminal ← latched session statuses pumps failure
          seen ← readIORef statuses
          pure (ended, seconds, failure, isJust closing, seen, terminal)
    let ((blocked, ended), seconds, failure, closing, seen, terminal) = evidence
    pure
      ( "compositor "
          <> compositorVersion compositor
          <> " ended ("
          <> show ended
          <> ") once wait "
          <> show blocked
          <> " was observed blocked; the wait returned after "
          <> show seconds
          <> "s of a "
          <> show lossWaitBound
          <> "s bound; "
          <> describeLoss failure
          <> "; GLFW's own close request "
          <> (if closing then "surfaced and was rejected" else "did not surface")
          <> "; probe statuses "
          <> show seen
          <> "; "
          <> terminal
          <> "; "
          <> teardown
      )

-- | The negative control: an injected close request on a healthy connection,
-- rejected by the application, with the compositor kept running throughout.
healthyCloseRequest ∷ IO String
healthyCloseRequest =
  withPrivateCompositor $ \compositor → do
    (statuses, pumps, native) ← observedNative
    enterPrivate compositor
    (rejected, running) ←
      withScoped (allocComposite (sessionAssembly native waylandConfig)) $ \session → do
        requireWayland session
        withWindow session (hiddenTestWindowConfig "asked to close" 200 150) $ \window → do
          injectCloseForCheck (windowNativeHandle window)
          processWindowEvents session ProcessPending
          request ← closeRequestOf window
          rejected ← rejectCloseRequest window request
          processWindowEvents session ProcessPending
          processWindowEvents session (AwaitEventsFor 0.05)
          after ← synchronizeWindow window
          case after of
            WindowAvailable _ → pure ()
            WindowEnded _ → failCheck "the window ended after a rejected close request"
          running ← compositorRunning compositor
          pure (rejected, running)
    seen ← readIORef statuses
    pumped ← readIORef pumps
    unless (rejected == WindowAvailable True) $ failCheck ("the application's rejection answered " <> show rejected)
    unless running $ failCheck "the healthy control's compositor was not running"
    unless (length seen == 2 * pumped && all (== ConnectionHealthy) seen) $
      failCheck ("the probe answered " <> show seen <> " around " <> show pumped <> " pump(s)")
    pure
      ( "injected close request rejected by the application; compositor "
          <> compositorVersion compositor
          <> " kept running; the probe answered healthy at all "
          <> show (length seen)
          <> " boundaries of "
          <> show pumped
          <> " pumps; the session stayed live and ended cleanly. This is not evidence of a compositor-generated close request."
      )

-- ---------------------------------------------------------------------------
-- Connection-loss helpers

-- | How long the loss-in-wait owner waits: far beyond the compositor's exit,
-- so reaching it means the loss did not end the wait.
lossWaitBound ∷ Double
lossWaitBound = 30

-- | A production table recording every probe status and counting every pump.
observedNative ∷ IO (IORef [ConnectionStatus], IORef Int, Native)
observedNative = do
  statuses ← newIORef []
  pumps ← newIORef 0
  let recording (ConnectionProbe probe) =
        ConnectionProbe (probe >>= \status → modifyIORef' statuses (<> [status]) >> pure status)
      counted action = modifyIORef' pumps (+ 1) >> action
      native =
        productionNative
          { nativeConnectionProbe = fmap recording <$> nativeConnectionProbe productionNative
          , nativePollEvents = counted (nativePollEvents productionNative)
          , nativeWaitEventsTimeout = counted . nativeWaitEventsTimeout productionNative
          }
  pure (statuses, pumps, native)

-- | Enter a Wayland session on the private compositor over a table, run the
-- body, and keep what it established even when the teardown of a session
-- whose compositor is gone reports failures, which are described instead.
lostSession ∷ Compositor → Native → (Session → IO a) → IO (a, String)
lostSession compositor native body = do
  enterPrivate compositor
  kept ← newIORef Nothing
  outcome ←
    try . withScoped (allocComposite (sessionAssembly native waylandConfig)) $ \session → do
      requireWayland session
      body session >>= writeIORef kept . Just
  readIORef kept >>= \case
    Nothing → either throwIO (\() → failCheck "the session body kept nothing") outcome
    Just result →
      pure
        ( result
        , either
            (\thrown → "the teardown after the loss reported " <> displayException (thrown ∷ SomeException))
            (\() → "the teardown after the loss reported nothing")
            outcome
        )

-- | Run one event processing that must fail with the loss, answering the
-- failure and the pump counts on either side of it.
confirmedLoss ∷ Session → IORef Int → EventProcessing → IO (ConnectionFailed, Int, Int)
confirmedLoss session pumps processing = do
  before ← readIORef pumps
  outcome ← try (processWindowEvents session processing)
  after ← readIORef pumps
  failure ← case outcome of
    Left thrown → maybe (failCheck ("unexpected failure: " <> displayException (thrown ∷ SomeException))) pure (fromException thrown)
    Right () → failCheck "event processing on the lost connection succeeded"
  pure (failure, before, after)

-- | The session is terminal: a later processing raises the same failure with
-- no probe and no pump.
latched ∷ Session → IORef [ConnectionStatus] → IORef Int → ConnectionFailed → IO String
latched session statuses pumps failure = do
  probed ← length <$> readIORef statuses
  pumped ← readIORef pumps
  (again, _, _) ← confirmedLoss session pumps ProcessPending
  probedAfter ← length <$> readIORef statuses
  pumpedAfter ← readIORef pumps
  unless (again == failure) $ failCheck ("a later processing raised " <> show again)
  unless (probedAfter == probed && pumpedAfter == pumped) $
    failCheck "a later processing probed or pumped the lost connection again"
  pure "a later processing raised the same failure with no probe and no pump"

requireLoss ∷ ConnectionFailed → EventBoundary → IO ()
requireLoss failure boundary = do
  case connectionCause failure of
    TransportClosed _ → pure ()
    other → failCheck ("the loss was reported as " <> show other <> ", not a transport closure")
  unless (connectionBoundary failure == boundary) $
    failCheck ("the loss was found " <> show (connectionBoundary failure) <> ", not " <> show boundary)

describeLoss ∷ ConnectionFailed → String
describeLoss failure =
  "confirmed "
    <> show (connectionCause failure)
    <> " "
    <> show (connectionBoundary failure)
    <> ": "
    <> displayException failure

-- | End the compositor once the owner's wait is observed blocked inside GLFW,
-- answering that wait's sequence number and the compositor's exit; 'Nothing'
-- when the owner finished first.
endWhenBlocked ∷ TVar Bool → Natural → Compositor → IO (Maybe (Natural, ExitCode))
endWhenBlocked ownerDone floor' compositor = loop
  where
    loop = do
      done ← readTVarIO ownerDone
      if done
        then pure Nothing
        else
          blockedWaitForCheck >>= \case
            Just blocked | blocked > floor' → do
              ended ← endCompositor compositor
              pure (Just (blocked, ended))
            _ → yield >> loop

-- ---------------------------------------------------------------------------
-- The private compositor

-- | A compositor this child started and owns.
data Compositor = Compositor
  { compositorDirectory ∷ !FilePath
    -- ^ Its private runtime directory, mode 0700.
  , compositorSocket ∷ !String
    -- ^ The socket's name inside that directory.
  , compositorProcess ∷ !ProcessHandle
  , compositorVersion ∷ !String
    -- ^ What @weston --version@ answered.
  }

-- | Start packaged Weston headless on a socket of this child's own, wait until
-- that socket is served, lend it to the body, and end it and remove its
-- directory on every exit path. A compositor that is missing, exits, or never
-- serves its socket fails the check.
withPrivateCompositor ∷ (Compositor → IO a) → IO a
withPrivateCompositor body =
  withPrivateDirectory "hetoimasia-private-wayland." $ \directory → do
    pid ← getProcessID
    let socket = "hetoimasia-private-" <> show pid
    environment ← compositorEnvironment directory
    version ←
      launchCommandIn (Just environment) readinessDeadline "weston" ["--version"] >>= \case
        Launched (ChildExited ExitSuccess) out _ _ → pure (takeWhile (/= '\n') out)
        Launched end _ err _ → failCheck ("weston --version ended " <> show end <> ": " <> err)
    bracket
      ( do
          out ← openFile (directory </> "compositor.out") WriteMode
          err ← openFile (directory </> "compositor.err") WriteMode
          (_, _, _, handle) ←
            createProcess
              ( proc
                  "weston"
                  ["--backend=headless", "--socket=" <> socket, "--width=1280", "--height=1024", "--no-config", "--idle-time=0"]
              )
                { env = Just environment
                , std_in = NoStream
                , std_out = UseHandle out
                , std_err = UseHandle err
                }
          pure handle
      )
      (\handle → getProcessExitCode handle >>= maybe (() <$ stopProcess handle) (\_ → pure ()))
      ( \handle → do
          let compositor = Compositor directory socket handle version
          awaitServed compositor environment readinessAttempts
          body compositor
      )
  where
    awaitServed compositor environment remaining = do
      exited ← getProcessExitCode (compositorProcess compositor)
      forM_ exited $ \code → do
        logged ← compositorLog compositor
        failCheck ("the private compositor exited " <> show code <> " before serving its socket: " <> logged)
      served ←
        launchCommandIn
          (Just (("WAYLAND_DISPLAY", compositorSocket compositor) : environment))
          readinessDeadline
          "wayland-info"
          []
      case launchedEnd served of
        ChildExited ExitSuccess → pure ()
        _
          | remaining <= (0 ∷ Int) → do
              logged ← compositorLog compositor
              failCheck ("the private compositor never served " <> compositorSocket compositor <> ": " <> logged)
          | otherwise → threadDelay 100000 >> awaitServed compositor environment (remaining - 1)

-- | The compositor's environment: this process's, with the runtime directory
-- its own, no configuration root to read, and nothing naming another display.
compositorEnvironment ∷ FilePath → IO [(String, String)]
compositorEnvironment directory = do
  inherited ← getEnvironment
  let removed = ["WAYLAND_DISPLAY", "WAYLAND_SOCKET", "DISPLAY", "WESTON_CONFIG_FILE", "XDG_RUNTIME_DIR", "XDG_CONFIG_HOME", "XDG_SESSION_TYPE"]
  pure
    ( [(name, value) | (name, value) ← inherited, name `notElem` removed]
        <> [ ("XDG_RUNTIME_DIR", directory)
           , ("XDG_CONFIG_HOME", directory </> "config")
           , ("XDG_SESSION_TYPE", "wayland")
           ]
    )

-- | Point this child's own sessions at the private compositor, and nothing
-- else: the socket by absolute path, and the runtime directory with it.
enterPrivate ∷ Compositor → IO ()
enterPrivate compositor = do
  unsetEnv "WAYLAND_SOCKET"
  unsetEnv "DISPLAY"
  setEnv "XDG_RUNTIME_DIR" (compositorDirectory compositor)
  setEnv "WAYLAND_DISPLAY" (compositorDirectory compositor </> compositorSocket compositor)

-- | End the compositor: @SIGTERM@, then its exit, within a bound.
endCompositor ∷ Compositor → IO ExitCode
endCompositor = stopProcess . compositorProcess

compositorRunning ∷ Compositor → IO Bool
compositorRunning compositor = maybe True (const False) <$> getProcessExitCode (compositorProcess compositor)

-- | Terminate a process this child started and wait for its exit, failing the
-- check if it does not exit within 'readinessDeadline'.
stopProcess ∷ ProcessHandle → IO ExitCode
stopProcess handle = do
  terminateProcess handle
  exited ← newTVarIO Nothing
  _ ← forkIO (waitForProcess handle >>= atomically . writeTVar exited . Just)
  timer ← registerDelay (round (readinessDeadline * 1000000))
  atomically ((Just <$> (readTVar exited >>= maybe retry pure)) `orElse` (Nothing <$ (readTVar timer >>= check)))
    >>= maybe (failCheck "the private compositor did not exit after SIGTERM") pure

compositorLog ∷ Compositor → IO String
compositorLog compositor = do
  logged ←
    mapM
      (\name → either (\(_ ∷ SomeException) → "") id <$> try (readFile (compositorDirectory compositor </> name)))
      ["compositor.out", "compositor.err"]
  pure (unwords (lines (concat logged)))

-- | How long one readiness probe, the version query, or the compositor's exit
-- may take.
readinessDeadline ∷ Double
readinessDeadline = 10

-- | How many readiness probes may fail before the compositor is judged never
-- to serve its socket; with the pause between them, about ten seconds.
readinessAttempts ∷ Int
readinessAttempts = 100

-- | A fresh directory of this child's own, mode 0700, removed on every exit.
withPrivateDirectory ∷ String → (FilePath → IO a) → IO a
withPrivateDirectory prefix = bracket create removeDirectoryRecursive
  where
    create = do
      base ← getTemporaryDirectory
      mkdtemp (base </> prefix)

-- ---------------------------------------------------------------------------
-- Shared helpers

waylandConfig ∷ SessionConfig
waylandConfig = defaultSessionConfig {requestedBackend = Just Wayland}

requireWayland ∷ Session → IO ()
requireWayland session =
  unless (sessionBackend session == Wayland) $
    failCheck ("the session selected " <> show (sessionBackend session) <> ", not Wayland")

-- | Fail unless the failure is attributed to the glfw component's operation,
-- for the backend named.
requireOrigin ∷ SomeException → String → String → IO ()
requireOrigin caught operationName backend = case failureCause (failureEvidence caught) of
  EngineOrigin origin → do
    let component = Text.unpack (componentText (originComponent origin))
        named = Text.unpack (operationText (originOperation origin))
        identifiers = originIdentifiers origin
    unless (component == "glfw" && named == operationName && lookup "backend" identifiers == Just (Text.pack backend)) $
      failCheck ("attributed to " <> component <> " " <> named <> " " <> show identifiers)
  NativeCause → failCheck "the failure carries no engine origin"

-- | The platform's primary monitor, or its first when it designates none.
selectedMonitor ∷ Session → IO MonitorDescription
selectedMonitor session =
  inventoryMonitors <$> synchronizeMonitors session >>= \case
    Observed monitors@(firstMonitor : _) → pure (maybe firstMonitor id (find ((== Observed True) . monitorPrimary) monitors))
    Observed [] → failCheck "the compositor exposes no monitor"
    Unavailable → failCheck "the monitor enumeration was inconsistent"

synchronized ∷ Window → IO WindowObservation
synchronized window =
  synchronizeWindow window >>= \case
    WindowAvailable observation → pure observation
    WindowEnded _ → failCheck "a live window answered as ended"

closeRequestOf ∷ Window → IO CloseRequest
closeRequestOf window =
  observedCloseRequest <$> synchronized window >>= maybe (failCheck "no close request surfaced") pure

-- | @GLFW_PLATFORM_UNAVAILABLE@, which GLFW reports when it cannot reach an X11
-- display.
platformUnavailableCode ∷ Int
platformUnavailableCode = fromIntegral glfwPlatformUnavailable

failCheck ∷ String → IO a
failCheck = ioError . userError
