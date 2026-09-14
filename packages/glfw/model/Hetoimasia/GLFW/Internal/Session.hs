-- | The GLFW session model, written over a table of native operations.
--
-- A 'Session' is the one scoped owner of GLFW's process-wide state: its
-- initialization, the error callback and the bookkeeping behind it, the
-- creation seam, and final termination. 'sessionAssembly' constructs it in
-- stages under 'Hetoimasia.Foundation.Resource.withComposite''s staged
-- protection, so a failure at any stage releases exactly what was acquired
-- before it, keeping the triggering failure primary and every cleanup failure
-- beside it.
--
-- The production table is "Hetoimasia.GLFW.Internal.Native"; the test seam
-- supplies a scripted one. Everything here — thread checks, exclusivity,
-- attribution of native errors, rollback, and poisoning — is the same code in
-- both, which is what lets CPU examples prove it without initializing GLFW.
--
-- = Entry
--
-- In order, before any native state changes:
--
-- 1. The requested backend is resolved against the one this platform
--    supports. Wayland is never selected, and a request for it, or for any
--    backend this platform does not support, fails with 'UnsupportedBackend'.
-- 2. The calling thread must be bound and must be the OS thread that entered
--    the process main function, or entry fails with 'NotProcessMainThread'. A
--    bound worker thread is not enough, and neither is an unbound thread that
--    happens to run there, which could migrate. The threaded runtime is
--    therefore required.
-- 3. The process-wide 'Guard' is claimed. An active session, from any thread,
--    fails the claim with 'SessionAlreadyActive', and a poisoned guard with
--    'SessionPoisoned'.
--
-- Only then does construction query platform support, install the error
-- callback, set the initialization hints, initialize, and confirm that the
-- initialized platform is the selected backend.
--
-- = Owner-only operations
--
-- 'takeAsynchronousReports' and the creation seam check, before any native
-- call, that they run on the thread that entered the session
-- ('NotSessionOwner') and that the session has not ended ('SessionEnded').
--
-- = Native errors
--
-- Each native call an operation makes is bracketed by the capture described in
-- "Hetoimasia.GLFW.Internal.Capture": reports made on the process main thread
-- during the call belong to the operation and fail it with a 'NativeFailure'
-- raised through 'throwFailure', which attaches the @glfw@ component, the
-- operation, and its identifiers. Asynchronous reports are never attributed to
-- the operation; they are read with 'takeAsynchronousReports', and any still
-- unread when the session ends are retained as cleanup evidence.
--
-- A native constructor that returns a live handle has its release registered
-- before any report from the same call is raised.
--
-- = Teardown and poisoning
--
-- Release order is declared, not reversed: terminate, then detach the error
-- callback and free its storage, then settle the guard. A release reads native
-- errors after its call returns, logs nothing, pumps no events, and waits for no
-- other thread, so each has the controlled blocking duration an uninterruptible
-- release requires: its native calls are bounded GLFW calls on the owner thread,
-- and its bookkeeping is a non-blocking 'IORef' update.
--
-- Callback storage is freed only after the callback has been detached on the
-- owner thread and every earlier teardown step ended safely, because only then
-- can GLFW no longer invoke it: this package makes every native call on the
-- owner thread, and GLFW reports errors from inside the failing call. If a
-- teardown step raises instead of returning — termination, detaching the
-- callback, or a release attempted from another thread — the storage is
-- deliberately leaked and the guard is poisoned, so every later entry fails
-- with 'SessionPoisoned' before any native call. A native error reported by a
-- release whose call returned does not poison: it is retained as that
-- release's cleanup failure.
--
-- = State
--
-- +--------------------+-------------------+----------------------+-------------+--------------------+-----------------------+
-- | State              | Owner             | Readers, writers     | Thread      | Lifetime           | Reset or disposal     |
-- +====================+===================+======================+=============+====================+=======================+
-- | Guard occupancy    | The native table  | Entry claims it; the | Any; atomic | The process        | Vacant after a safe   |
-- | and poison         | ('Guard')         | final release        |             |                    | teardown; poisoned    |
-- |                    |                   | settles it           |             |                    | forever otherwise     |
-- +--------------------+-------------------+----------------------+-------------+--------------------+-----------------------+
-- | Error capture      | The session       | The callback writes; | Callback:   | Construction until | Unread asynchronous   |
-- | buckets            |                   | owner operations and | any; takes: | the callback is    | reports become        |
-- |                    |                   | releases take        | owner       | detached           | cleanup evidence      |
-- +--------------------+-------------------+----------------------+-------------+--------------------+-----------------------+
-- | Callback storage   | The session       | Installed at entry;  | Owner       | Until detached     | Freed after a safe    |
-- |                    |                   | freed at teardown    |             |                    | detach; leaked when   |
-- |                    |                   |                      |             |                    | poisoned              |
-- +--------------------+-------------------+----------------------+-------------+--------------------+-----------------------+
-- | Teardown safety    | The session       | Releases clear it;   | Owner       | The session        | Read once by the      |
-- |                    |                   | the guard release    |             |                    | guard release         |
-- |                    |                   | reads it             |             |                    |                       |
-- +--------------------+-------------------+----------------------+-------------+--------------------+-----------------------+
-- | Liveness           | The session       | Termination clears   | Owner       | The session        | Never set again       |
-- |                    |                   | it; operations read  |             |                    |                       |
-- +--------------------+-------------------+----------------------+-------------+--------------------+-----------------------+
--
-- Nothing here is application state, and nothing is shared between sessions
-- except the guard.
module Hetoimasia.GLFW.Internal.Session
  ( -- * Backends and configuration
    Backend (..)
  , backendText
  , SessionConfig (..)
  , defaultSessionConfig

    -- * The native operations a session performs
  , Native (..)
  , NativeWindow
  , CallbackStorage (..)
  , WindowHint (..)

    -- * Exclusivity
  , Guard
  , newGuard

    -- * Sessions
  , Session
  , sessionAssembly
  , sessionBackend
  , takeAsynchronousReports

    -- * The private window creation seam
  , WindowRequest (..)
  , WindowVisibility (..)
  , nativeWindowAssembly
  , windowAssemblyThrough

    -- * Failures
  , glfwComponent
  , SessionMisuse (..)
  , UnsupportedBackend (..)
  , BackendNotSelected (..)
  , NativeOutcome (..)
  , NativeFailure (..)
  , AsynchronousErrorsUnobserved (..)

    -- * Error evidence
  , NativeError (..)
  , ReportingThread (..)
  , Reports (..)
  , errorEvidenceCapacity
  , errorDescriptionLimit
  ) where

import Control.Concurrent (ThreadId, isCurrentThreadBound, myThreadId)
import Control.Exception (Exception, onException)
import Control.Monad (unless, when)
import Data.IORef (IORef, atomicModifyIORef', atomicWriteIORef, newIORef, readIORef)
import Data.Int (Int32)
import Data.Text (Text)
import Foreign.Ptr (FunPtr, Ptr, nullPtr)
import Hetoimasia.Foundation.Failure (Operation, operation, throwFailure)
import Hetoimasia.Foundation.Log (Component, unsafeComponent)
import Hetoimasia.Foundation.Resource (Assembly, acquirePart, releaseRank, restoredStep)
import Hetoimasia.GLFW.Internal.Capture
  ( Capture
  , ErrorCallback
  , NativeError (..)
  , ReportingThread (..)
  , Reports (..)
  , captureCallback
  , errorDescriptionLimit
  , errorEvidenceCapacity
  , hasReports
  , newCapture
  , settleStrayOwnerReports
  , takeOtherReports
  , takeOwnerReports
  )

-- | A GLFW platform backend.
data Backend
  = X11
    -- ^ Selected explicitly on Linux.
  | Cocoa
    -- ^ Selected explicitly on macOS.
  | Wayland
    -- ^ Never selected: requesting it is always 'UnsupportedBackend'.
  deriving (Eq, Show)

-- | The backend's name in failure identifiers.
backendText ∷ Backend → Text
backendText X11 = "x11"
backendText Cocoa = "cocoa"
backendText Wayland = "wayland"

-- | What the application asks of a session. It is a pure value, checked before
-- anything is acquired, and it never changes the process working directory.
data SessionConfig = SessionConfig
  { requestedBackend ∷ !(Maybe Backend)
    -- ^ 'Nothing' selects the backend this platform supports.
  }
  deriving (Eq, Show)

-- | The platform's own backend.
defaultSessionConfig ∷ SessionConfig
defaultSessionConfig = SessionConfig {requestedBackend = Nothing}

-- | GLFW's opaque window object. A pointer to it never leaves this package.
data NativeWindow

-- | The storage behind an installed error callback.
newtype CallbackStorage = CallbackStorage (FunPtr ErrorCallback)

-- | The creation hints the seam sets.
data WindowHint
  = NoClientApi
  | NotVisible
  | NotFocused
  | NoFocusOnShow
  deriving (Eq, Show)

-- | Every native operation a session performs, as the model sees it.
data Native = Native
  { nativeHostBackend ∷ !(Maybe Backend)
    -- ^ The backend this platform supports, if any.
  , nativeGuard ∷ !Guard
    -- ^ The exclusivity guard sessions over this library share.
  , nativeIsProcessMainThread ∷ IO Bool
    -- ^ Whether the calling OS thread entered the process main function.
  , nativePlatformSupported ∷ Backend → IO Bool
  , nativeNewErrorCallback ∷ ErrorCallback → IO CallbackStorage
    -- ^ Allocate callback storage; changes no native state.
  , nativeAttachErrorCallback ∷ CallbackStorage → IO ()
  , nativeDetachErrorCallback ∷ IO ()
  , nativeFreeErrorCallback ∷ CallbackStorage → IO ()
  , nativeSetInitHints ∷ Backend → IO ()
    -- ^ Select the platform, and keep the working directory unchanged.
  , nativeInitialize ∷ IO Bool
  , nativeCurrentBackend ∷ IO (Maybe Backend)
  , nativeTerminate ∷ IO ()
  , nativeResetWindowHints ∷ IO ()
  , nativeSetWindowHint ∷ WindowHint → IO ()
  , nativeCreateWindow ∷ Int32 → Int32 → Text → IO (Ptr NativeWindow)
  , nativeDestroyWindow ∷ Ptr NativeWindow → IO ()
  }

-- | Which session, if any, holds a native library's process-wide state.
--
-- It holds only occupancy and poison, and nothing about the session holding it.
newtype Guard = Guard (IORef Occupancy)

data Occupancy = Vacant | Occupied | Poisoned

-- | A vacant guard.
newGuard ∷ IO Guard
newGuard = Guard <$> newIORef Vacant

-- | The one live GLFW session. Its representation is private to this package.
data Session = Session
  { sessionNative ∷ !Native
  , sessionOwner ∷ !ThreadId
  , sessionSelected ∷ !Backend
  , sessionCapture ∷ !Capture
  , sessionLive ∷ !(IORef Bool)
  }

-- | The backend the session initialized.
sessionBackend ∷ Session → Backend
sessionBackend = sessionSelected

-- | The component every failure raised by this package is attributed to.
glfwComponent ∷ Component
glfwComponent = unsafeComponent "glfw"

-- | Misuse rejected before any native state changes.
data SessionMisuse
  = NotProcessMainThread
    -- ^ Entry from a thread that is not the bound process main thread.
  | NotSessionOwner
    -- ^ An owner-only operation from a thread other than the owner.
  | SessionAlreadyActive
    -- ^ Entry while another session is active, from any thread.
  | SessionPoisoned
    -- ^ Entry after a teardown that could not establish it ended safely.
  | SessionEnded
    -- ^ An owner-only operation after the session's scope ended.
  deriving (Eq, Show)

instance Exception SessionMisuse

-- | A backend request this package does not satisfy on this platform.
data UnsupportedBackend = UnsupportedBackend
  { unsupportedRequest ∷ !(Maybe Backend)
    -- ^ What was requested; 'Nothing' for the platform default.
  , unsupportedPlatformBackend ∷ !(Maybe Backend)
    -- ^ The backend this platform supports, if any.
  }
  deriving (Eq, Show)

instance Exception UnsupportedBackend

-- | GLFW initialized a platform other than the one selected.
data BackendNotSelected = BackendNotSelected
  { selectionRequested ∷ !Backend
  , selectionReported ∷ !(Maybe Backend)
  }
  deriving (Eq, Show)

instance Exception BackendNotSelected

-- | Whether the native call itself signalled failure.
data NativeOutcome
  = NativeCallReturned
    -- ^ The call returned normally, but errors were reported during it.
  | NativeCallFailed
    -- ^ The call returned its failure value.
  deriving (Eq, Show)

-- | A native call failed or reported errors on the owner thread while it ran.
data NativeFailure = NativeFailure
  { nativeOutcome ∷ !NativeOutcome
  , nativeReports ∷ !Reports
  }
  deriving (Eq, Show)

instance Exception NativeFailure

-- | Asynchronous reports nobody read before the session ended.
newtype AsynchronousErrorsUnobserved = AsynchronousErrorsUnobserved Reports
  deriving (Eq, Show)

instance Exception AsynchronousErrorsUnobserved

enterSession, initializeOperation, verifyOperation, terminateOperation, detachOperation ∷ Operation
enterSession = operation "enter session"
initializeOperation = operation "initialize"
verifyOperation = operation "verify backend"
terminateOperation = operation "terminate"
detachOperation = operation "detach error callback"

takeReportsOperation, createWindowOperation, destroyWindowOperation ∷ Operation
takeReportsOperation = operation "take asynchronous reports"
createWindowOperation = operation "create window"
destroyWindowOperation = operation "destroy window"

backendIdentifiers ∷ Backend → [(Text, Text)]
backendIdentifiers backend = [("backend", backendText backend)]

-- | Construct a session over a native table.
--
-- The stages and their releases:
--
-- +-----------------------------+------------------------------+---------------+
-- | Stage                       | Release                      | Release order |
-- +=============================+==============================+===============+
-- | Resolve backend, check      | none                         |               |
-- | thread                      |                              |               |
-- +-----------------------------+------------------------------+---------------+
-- | Claim the guard             | Vacate, or poison            | third         |
-- +-----------------------------+------------------------------+---------------+
-- | Query platform support      | none                         |               |
-- +-----------------------------+------------------------------+---------------+
-- | Install the error callback  | Detach, then free if safe    | second        |
-- +-----------------------------+------------------------------+---------------+
-- | Set hints and initialize    | Terminate                    | first         |
-- +-----------------------------+------------------------------+---------------+
-- | Raise initialization        | none                         |               |
-- | reports; verify the backend |                              |               |
-- +-----------------------------+------------------------------+---------------+
sessionAssembly ∷ Native → SessionConfig → Assembly Session
sessionAssembly native config = do
  backend ← restoredStep (admit native config)
  owner ← restoredStep myThreadId
  teardown ← restoredStep (newIORef True)
  live ← restoredStep (newIORef True)
  capture ← restoredStep (newCapture (nativeIsProcessMainThread native))
  acquirePart
    "glfw session occupancy"
    (releaseRank 2)
    (claimGuard (nativeGuard native) backend)
    (\() → settleGuard (nativeGuard native) teardown)
  restoredStep (requireSupported native backend)
  _ ←
    acquirePart
      "glfw error callback"
      (releaseRank 1)
      (attachCallback native capture teardown)
      (detachCallback native capture owner teardown)
  initialized ←
    acquirePart
      "glfw terminate"
      (releaseRank 0)
      (initialize native capture teardown backend)
      (\_ → terminate native capture owner teardown live backend)
  restoredStep $ do
    raiseReported initializeOperation (backendIdentifiers backend) NativeCallReturned initialized
    verifySelected native capture backend
  pure
    Session
      { sessionNative = native
      , sessionOwner = owner
      , sessionSelected = backend
      , sessionCapture = capture
      , sessionLive = live
      }

admit ∷ Native → SessionConfig → IO Backend
admit native config = do
  backend ←
    either
      (throwFailure glfwComponent enterSession requestIdentifiers)
      pure
      (resolveBackend (nativeHostBackend native) (requestedBackend config))
  bound ← isCurrentThreadBound
  onMain ← nativeIsProcessMainThread native
  unless (bound && onMain) $
    throwFailure glfwComponent enterSession (backendIdentifiers backend) NotProcessMainThread
  pure backend
  where
    requestIdentifiers = maybe [] backendIdentifiers (requestedBackend config)

resolveBackend ∷ Maybe Backend → Maybe Backend → Either UnsupportedBackend Backend
resolveBackend platform request =
  case (request, platform) of
    (Nothing, Just supported) | supported /= Wayland → Right supported
    (Just wanted, Just supported) | wanted == supported, wanted /= Wayland → Right wanted
    _ → Left (UnsupportedBackend request platform)

claimGuard ∷ Guard → Backend → IO ()
claimGuard (Guard occupancy) backend = do
  refused ← atomicModifyIORef' occupancy $ \state → case state of
    Vacant → (Occupied, Nothing)
    Occupied → (Occupied, Just SessionAlreadyActive)
    Poisoned → (Poisoned, Just SessionPoisoned)
  mapM_ (throwFailure glfwComponent enterSession (backendIdentifiers backend)) refused

settleGuard ∷ Guard → IORef Bool → IO ()
settleGuard (Guard occupancy) teardown = do
  safe ← readIORef teardown
  atomicWriteIORef occupancy (if safe then Vacant else Poisoned)

requireSupported ∷ Native → Backend → IO ()
requireSupported native backend = do
  supported ← nativePlatformSupported native backend
  unless supported $
    throwFailure
      glfwComponent
      enterSession
      (backendIdentifiers backend)
      (UnsupportedBackend (Just backend) (nativeHostBackend native))

attachCallback ∷ Native → Capture → IORef Bool → IO CallbackStorage
attachCallback native capture teardown = do
  storage ← nativeNewErrorCallback native (captureCallback capture)
  -- An attachment that raises may or may not have registered the callback, so
  -- its storage is never freed and the guard is poisoned.
  nativeAttachErrorCallback native storage `onException` atomicWriteIORef teardown False
  pure storage

initialize ∷ Native → Capture → IORef Bool → Backend → IO Reports
initialize native capture teardown backend = do
  settleStrayOwnerReports capture
  nativeSetInitHints native backend
  -- An initialization that raises leaves GLFW's state unknown; nothing is
  -- registered to terminate it, so the guard is poisoned instead.
  initialized ← nativeInitialize native `onException` atomicWriteIORef teardown False
  reports ← takeOwnerReports capture
  unless initialized $
    throwFailure
      glfwComponent
      initializeOperation
      (backendIdentifiers backend)
      (NativeFailure NativeCallFailed reports)
  pure reports

verifySelected ∷ Native → Capture → Backend → IO ()
verifySelected native capture backend = do
  settleStrayOwnerReports capture
  reported ← nativeCurrentBackend native
  reports ← takeOwnerReports capture
  raiseReported verifyOperation (backendIdentifiers backend) NativeCallReturned reports
  unless (reported == Just backend) $
    throwFailure
      glfwComponent
      verifyOperation
      (backendIdentifiers backend)
      (BackendNotSelected backend reported)

terminate ∷ Native → Capture → ThreadId → IORef Bool → IORef Bool → Backend → IO ()
terminate native capture owner teardown live backend =
  ownerRelease owner teardown terminateOperation $ do
    atomicWriteIORef live False
    settleStrayOwnerReports capture
    nativeTerminate native `onException` atomicWriteIORef teardown False
    reports ← takeOwnerReports capture
    raiseReported terminateOperation (backendIdentifiers backend) NativeCallReturned reports

detachCallback ∷ Native → Capture → ThreadId → IORef Bool → CallbackStorage → IO ()
detachCallback native capture owner teardown storage =
  ownerRelease owner teardown detachOperation $ do
    nativeDetachErrorCallback native `onException` atomicWriteIORef teardown False
    safe ← readIORef teardown
    when safe (nativeFreeErrorCallback native storage)
    settleStrayOwnerReports capture
    unobserved ← takeOtherReports capture
    when (hasReports unobserved) $
      throwFailure glfwComponent detachOperation [] (AsynchronousErrorsUnobserved unobserved)

-- | Run a release only on the owner thread. From any other thread it makes no
-- native call, marks the teardown unsafe, and fails.
ownerRelease ∷ ThreadId → IORef Bool → Operation → IO () → IO ()
ownerRelease owner teardown operationName release = do
  caller ← myThreadId
  if caller == owner
    then release
    else do
      atomicWriteIORef teardown False
      throwFailure glfwComponent operationName [] NotSessionOwner

raiseReported ∷ Operation → [(Text, Text)] → NativeOutcome → Reports → IO ()
raiseReported operationName identifiers outcome reports =
  when (hasReports reports) $
    throwFailure glfwComponent operationName identifiers (NativeFailure outcome reports)

-- | Check the owner thread and liveness, then run an operation.
ownerOperation ∷ Session → Operation → [(Text, Text)] → IO a → IO a
ownerOperation session operationName identifiers action = do
  caller ← myThreadId
  when (caller /= sessionOwner session) $
    throwFailure glfwComponent operationName identifiers NotSessionOwner
  live ← readIORef (sessionLive session)
  unless live $
    throwFailure glfwComponent operationName identifiers SessionEnded
  action

-- | Take, and empty, the asynchronous reports: those made on another thread,
-- and those made on the owner thread outside any operation's native call.
takeAsynchronousReports ∷ Session → IO Reports
takeAsynchronousReports session =
  ownerOperation session takeReportsOperation [] $ do
    settleStrayOwnerReports (sessionCapture session)
    takeOtherReports (sessionCapture session)

-- | Whether a seam window may be shown.
data WindowVisibility
  = HiddenTestWindow
    -- ^ Hidden, unfocused, and not focused when shown.
  | ShownWindow
  deriving (Eq, Show)

-- | A NoAPI window the creation seam constructs.
data WindowRequest = WindowRequest
  { windowWidth ∷ !Int32
  , windowHeight ∷ !Int32
  , windowTitle ∷ !Text
  , windowVisibility ∷ !WindowVisibility
  }
  deriving (Eq, Show)

-- | Construct a NoAPI window in a live session, through the session's own
-- native table.
nativeWindowAssembly ∷ Session → WindowRequest → Assembly (Ptr NativeWindow)
nativeWindowAssembly session = windowAssemblyThrough (sessionNative session) session

-- | Construct a NoAPI window through the given native table.
--
-- Creation hints are reset before every window and NoAPI is set explicitly; a
-- hidden test window also disables focus and focus on show. A live handle's
-- destruction is registered before any error reported during its creation is
-- raised, so a creation that returned a handle and reported an error destroys
-- that handle while unwinding.
windowAssemblyThrough ∷ Native → Session → WindowRequest → Assembly (Ptr NativeWindow)
windowAssemblyThrough native session request = do
  (window, reports) ← acquirePart "glfw window" (releaseRank 0) create destroy
  restoredStep (raiseReported createWindowOperation identifiers NativeCallReturned reports)
  pure window
  where
    capture = sessionCapture session
    identifiers = [("title", windowTitle request)]

    create = ownerOperation session createWindowOperation identifiers $ do
      settleStrayOwnerReports capture
      nativeResetWindowHints native
      mapM_ (nativeSetWindowHint native) (windowHints (windowVisibility request))
      window ←
        nativeCreateWindow native (windowWidth request) (windowHeight request) (windowTitle request)
      reports ← takeOwnerReports capture
      when (window == nullPtr) $
        throwFailure glfwComponent createWindowOperation identifiers (NativeFailure NativeCallFailed reports)
      pure (window, reports)

    destroy (window, _) = ownerOperation session destroyWindowOperation identifiers $ do
      settleStrayOwnerReports capture
      nativeDestroyWindow native window
      reports ← takeOwnerReports capture
      raiseReported destroyWindowOperation identifiers NativeCallReturned reports

windowHints ∷ WindowVisibility → [WindowHint]
windowHints HiddenTestWindow = [NoClientApi, NotVisible, NotFocused, NoFocusOnShow]
windowHints ShownWindow = [NoClientApi]
