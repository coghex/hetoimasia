-- | The GLFW session model, written over a table of native operations.
--
-- A 'Session' is the one scoped owner of GLFW's process-wide state: its
-- initialization, the error callback and the bookkeeping behind it, the
-- identities of the windows created in it, and final termination.
-- 'sessionAssembly' constructs it in stages under 'Hetoimasia.Foundation.Resource.withComposite''s staged
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
-- 'takeAsynchronousReports', the monitor operations below, and the window
-- operations of "Hetoimasia.GLFW.Internal.Window" check, before any native call, that they
-- run on the thread that entered the session ('NotSessionOwner') and that the session has not ended ('SessionEnded').
--
-- = Waking the owner
--
-- 'sessionWake' lends the session's 'SessionWake' capability, which any thread
-- may use with 'wakeSession' to post GLFW's documented cross-thread empty event,
-- so an owner blocked in a native event wait returns. It is the one native call
-- this package makes off the owner thread; event pumping, waits, and every
-- window and monitor operation stay owner-only. The capability holds no native
-- handle and exposes no session representation.
--
-- A wake is a hint. It carries no message, may be coalesced with others, and
-- proves nothing about work; whatever state made it worth waking is
-- authoritative, and what to do after an expected platform failure is the
-- caller's policy. Only @GLFW_PLATFORM_ERROR@ evidence is such a failure; any
-- other evidence is raised, as 'wakeSession' describes.
--
-- A wake makes at most one native call plus bounded, non-blocking bookkeeping:
-- one STM transaction that never retries to be admitted, one to leave, and the
-- error capture's own updates. It invokes no caller-supplied IO and takes no
-- lock an owner operation or a callback could hold, so bound and unbound
-- threads, and the owner itself, may call it at any time.
--
-- = Wake lifetime
--
-- Each session owns a wake gate: open, closing with a count of admitted calls,
-- or closed. A wake is admitted by incrementing that count in the same
-- transaction that finds the gate open, and leaves by decrementing it after its
-- native call returns; admission and leaving run masked, so no asynchronous
-- exception can separate either from the native call it accounts for. A gate
-- that is not open answers 'WakeTerminal' without entering GLFW.
--
-- The session's first release closes the gate and then waits, uninterruptibly,
-- until every admitted call has left, before any later release runs: the
-- monitor callback's detach, termination, the error callback's detach, and every
-- free of callback storage all follow it. The wait is bounded by one native
-- empty-event post per admitted call. Closing never changes teardown safety,
-- so a session whose teardown was otherwise safe is not poisoned by it. A
-- capability retained after its session closed stays terminal forever, and
-- cannot reach any later session, which has a gate of its own. A construction
-- that rolls back never lends a capability at all.
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
-- Release order is declared, not reversed: close the wake gate and wait for
-- admitted wake calls, close the monitor inventory, detach
-- the monitor callback, terminate, detach the error callback and free its
-- storage, free the monitor callback's storage, then settle the guard. A release reads native
-- errors after its call returns, logs nothing, pumps no events, and waits for no
-- other thread, so each has the controlled blocking duration an uninterruptible
-- release requires: its native calls are bounded GLFW calls on the owner thread,
-- and its bookkeeping is a non-blocking 'IORef' update.
--
-- The monitor callback is detached before termination, and its storage stays
-- allocated through the error callback's detach, the session's last native
-- call. Callback storage is freed only after the callback has been detached on
-- the owner thread and every earlier teardown step ended safely, because only then
-- can GLFW no longer invoke it: this package makes every native call on the
-- owner thread, and GLFW reports errors from inside the failing call. If a
-- teardown step raises instead of returning — termination, detaching either
-- callback, or a release attempted from another thread — the storage is
-- deliberately leaked and the guard is poisoned, so every later entry fails
-- with 'SessionPoisoned' before any native call. A window release that leaves
-- its callbacks' reachability uncertain poisons the session the same way, and
-- the live session then refuses further windows. A native error reported by a
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
-- | Teardown safety    | The session       | Unsafe releases      | Owner       | The session        | Read once by the      |
-- |                    |                   | clear it; the guard  |             |                    | guard release         |
-- |                    |                   | release reads it     |             |                    |                       |
-- +--------------------+-------------------+----------------------+-------------+--------------------+-----------------------+
-- | Liveness           | The session       | Termination clears   | Owner       | The session        | Never set again       |
-- |                    |                   | it; operations read  |             |                    |                       |
-- +--------------------+-------------------+----------------------+-------------+--------------------+-----------------------+
-- | Monitor inventory, | The session       | See                  | Owner;      | Construction until | Closed first; every   |
-- | identities, and    |                   | "Hetoimasia.GLFW.    | callback    | the inventory      | identity ends         |
-- | callback latch     |                   | Internal.Monitor"    | inside      | closes             |                       |
-- |                    |                   |                      | owner calls |                    |                       |
-- +--------------------+-------------------+----------------------+-------------+--------------------+-----------------------+
-- | Monitor claims     | The session       | Fullscreen           | Owner       | The session        | Ended identities'     |
-- |                    |                   | transitions reserve  |             |                    | claims pruned; at     |
-- |                    |                   | and settle; window   |             |                    | most one per current  |
-- |                    |                   | release disposes     |             |                    | monitor               |
-- +--------------------+-------------------+----------------------+-------------+--------------------+-----------------------+
-- | Monitor callback   | The session       | Installed at entry;  | Owner       | Through the last   | Freed after a safe    |
-- | storage            |                   | detached before      |             | native call        | teardown; leaked when |
-- |                    |                   | termination          |             |                    | poisoned              |
-- +--------------------+-------------------+----------------------+-------------+--------------------+-----------------------+
-- | Wake gate and      | The session       | Wake calls enter and | Any; STM    | Construction until | Closed by the first   |
-- | admitted count     |                   | leave; the first     |             | the first release; | release, and never    |
-- |                    |                   | release closes and   |             | closed thereafter  | reopened              |
-- |                    |                   | drains it            |             |                    |                       |
-- +--------------------+-------------------+----------------------+-------------+--------------------+-----------------------+
-- | Wake reports       | The session's     | The callback writes  | Callback:   | One wake call's    | Removed when its call |
-- |                    | capture           | on the wake call's   | the wake's; | native call        | returns               |
-- |                    |                   | OS thread; the call  | take: the   |                    |                       |
-- |                    |                   | takes them           | wake's      |                    |                       |
-- +--------------------+-------------------+----------------------+-------------+--------------------+-----------------------+
-- | Interaction trace  | The session       | An activated probe   | Owner, and  | Stopped unless a   | Emptied by each take; |
-- |                    | ('Trace')         | starts, takes, and   | callbacks   | probe starts it;   | stopped storage holds |
-- |                    |                   | stops it; the pump,  | inside its  | never started by   | nothing               |
-- |                    |                   | the loop, and the    | pump calls; | the session, the   |                       |
-- |                    |                   | window callbacks     | atomic      | window model, or   |                       |
-- |                    |                   | offer records        |             | the runtime        |                       |
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

    -- * Waking the owner
  , SessionWake
  , sessionWake
  , wakeSession
  , WakeOutcome (..)
  , WakePath (..)
  , DegradationReport (..)
  , sessionWakePath
  , sessionNotificationsInFlight

    -- * The monitor inventory
  , monitorInventory
  , synchronizeMonitors
  , resolveMonitor
  , reconcileMonitorEvents
  , withResolvedMonitor
  , monitorClaims

    -- * Window capabilities
  , sessionWindowCapabilities
  , backendWindowCapabilities

    -- * What window operations share with the session
  , WindowAttribute (..)
  , WindowCallbacks (..)
  , WindowCallbackStorage (..)
  , sessionNative
  , sessionCapture
  , sessionTrace
  , sessionIdentity
  , sessionOwner
  , sessionClaims
  , liveMonitors
  , currentSessionMonitors
  , identifyWindowMonitor
  , refreshMonitors
  , resolveMonitorPointer
  , nextWindowIdentity
  , requireUnpoisoned
  , poisonSession
  , ownerOperation
  , raiseReported
  , createWindowOperation
  , destroyWindowOperation

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
import Control.Concurrent.STM (STM, TVar, atomically, newTVarIO, readTVar, retry, writeTVar)
import Control.Exception (Exception, ExceptionWithContext, SomeException, finally, mask_, onException, rethrowIO, tryWithContext, uninterruptibleMask_)
import Control.Monad (unless, when)
import Data.IORef (IORef, atomicModifyIORef', atomicWriteIORef, newIORef, readIORef)
import qualified Data.Map.Strict as Map
import Data.Int (Int32)
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Unique (Unique, newUnique)
import Foreign.C.Types (CDouble, CFloat, CInt, CUInt)
import Foreign.Ptr (FunPtr, Ptr)
import Hetoimasia.Foundation.Failure (Operation, operation, throwFailure)
import Hetoimasia.Foundation.Messaging.Snapshot (SnapshotReader)
import Hetoimasia.Foundation.Resource (Assembly, acquirePart, releaseRank, restoredStep, withResourceLabelled)
import Hetoimasia.GLFW.Internal.Attribute (Attribute)
import Hetoimasia.GLFW.Internal.Capture
  ( Capture
  , ErrorCallback
  , NativeError (..)
  , NativeFailure (..)
  , NativeOutcome (..)
  , ReportingThread (..)
  , Reports (..)
  , WakeMark
  , beginWakeReports
  , captureCallback
  , errorDescriptionLimit
  , errorEvidenceCapacity
  , glfwComponent
  , hasReports
  , newCapture
  , raiseReported
  , settleStrayOwnerReports
  , takeOtherReports
  , takeOwnerReports
  , takeWakeReports
  )
import Hetoimasia.GLFW.Internal.Control
  ( WindowCapabilities
  , WindowOperation (..)
  , WindowReport (..)
  , fullWindowCapabilities
  , windowCapabilities
  )
import Hetoimasia.GLFW.Internal.Mode (MonitorClaims, pruneClaims)
import Hetoimasia.GLFW.Internal.Trace (Trace, newTrace)
import Hetoimasia.GLFW.Internal.Monitor
  ( MonitorDescription
  , MonitorId
  , MonitorInventory
  , MonitorNative (..)
  , MonitorCallbackStorage
  , MonitorResult (..)
  , MonitorSource
  , Monitors
  , NativeMonitor
  , assembleMonitors
  , closeInventory
  , currentMonitors
  , identifyPointer
  , liveIdentities
  , monitorCallback
  , monitorLocalIdentity
  , monitorsReader
  , newMonitorCell
  , newMonitorSource
  , publishInitialInventory
  , reconcileInventory
  , resolveInventory
  , rethrowMonitorFault
  , sampleInitialInventory
  , synchronizeInventory
  , takeMonitorFault
  )
import Numeric.Natural (Natural)

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

-- | The creation hints a window sets after resetting every hint to its default.
data WindowHint
  = NoClientApi
    -- ^ @GLFW_CLIENT_API = GLFW_NO_API@.
  | VisibleHint !Bool
  | FocusedHint !Bool
  | FocusOnShowHint !Bool
  deriving (Eq, Show)

-- | The boolean window attributes an observation samples.
data WindowAttribute
  = FocusedAttribute
  | IconifiedAttribute
  | MaximizedAttribute
  | VisibleAttribute
  | DecoratedAttribute
    -- ^ The decoration GLFW holds for the window, which it applies whenever the
    -- window is not on a monitor.
  deriving (Eq, Show)

-- | The Haskell side of one window's native callbacks, as the model builds them.
--
-- Each takes exactly the fixed payload GLFW passes after the window pointer,
-- so the binding's wrapper only drops that pointer. Every one of them is
-- already contained by the model: it copies its payload, records it, and
-- returns, and nothing it raises reaches the native caller.
data WindowCallbacks = WindowCallbacks
  { onWindowSize ∷ CInt → CInt → IO ()
  , onFramebufferSize ∷ CInt → CInt → IO ()
  , onContentScale ∷ CFloat → CFloat → IO ()
  , onWindowPosition ∷ CInt → CInt → IO ()
  , onWindowFocus ∷ CInt → IO ()
  , onWindowIconify ∷ CInt → IO ()
  , onWindowMaximize ∷ CInt → IO ()
  , onWindowRefresh ∷ IO ()
  , onWindowClose ∷ IO ()
  , onKey ∷ CInt → CInt → CInt → CInt → IO ()
    -- ^ Physical key, scancode, action, and modifiers.
  , onChar ∷ CUInt → IO ()
    -- ^ Unicode code point.
  , onMouseButton ∷ CInt → CInt → CInt → IO ()
    -- ^ Button, action, and modifiers.
  , onCursorPos ∷ CDouble → CDouble → IO ()
  , onCursorEnter ∷ CInt → IO ()
  , onScroll ∷ CDouble → CDouble → IO ()
  }

-- | The storage behind one window's callback wrappers, one pointer per
-- callback in the order 'WindowCallbacks' declares them.
newtype WindowCallbackStorage = WindowCallbackStorage [FunPtr ()]

-- | Every native operation a session performs, as the model sees it.
data Native = Native
  { nativeHostBackend ∷ !(Maybe Backend)
    -- ^ The backend this platform selects when no request names one, if any.
  , nativeAdmittedBackends ∷ ![Backend]
    -- ^ Every backend this platform admits to the support check. A request
    -- naming none of them is 'UnsupportedBackend' before any native call, and
    -- an admitted one is never exchanged for another: nothing falls back.
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
    -- ^ Returns null when creation failed.
  , nativeDestroyWindow ∷ Ptr NativeWindow → IO ()
  , nativeNewWindowCallbacks ∷ WindowCallbacks → IO WindowCallbackStorage
    -- ^ Allocate callback wrappers; changes no native state.
  , nativeAttachWindowCallbacks ∷ Ptr NativeWindow → WindowCallbackStorage → IO ()
  , nativeDetachWindowCallbacks ∷ Ptr NativeWindow → IO ()
    -- ^ Replace every callback 'nativeAttachWindowCallbacks' set with none.
  , nativeFreeWindowCallbacks ∷ WindowCallbackStorage → IO ()
  , nativeWindowSize ∷ Ptr NativeWindow → IO (Int, Int)
    -- ^ The content area's size in screen coordinates.
  , nativeFramebufferSize ∷ Ptr NativeWindow → IO (Int, Int)
    -- ^ The framebuffer's size in pixels.
  , nativeContentScale ∷ Ptr NativeWindow → IO (Float, Float)
  , nativeWindowPosition ∷ Ptr NativeWindow → IO (Int, Int)
    -- ^ The content area's upper-left corner in desktop screen coordinates.
  , nativeWindowAttribute ∷ Ptr NativeWindow → WindowAttribute → IO Bool
  , nativePollEvents ∷ IO ()
    -- ^ Process the events already pending, without waiting.
  , nativeWaitEventsTimeout ∷ Double → IO ()
    -- ^ Wait at most this many seconds for an event, then process every
    -- pending event.
  , nativePostEmptyEvent ∷ WakeMark → IO Int
    -- ^ Post an empty event, from any thread, so a wait in progress returns.
    -- For the duration of the call the calling OS thread's wake mark is the one
    -- given, so the error callback attributes what the call reports to it; the
    -- answer is the error code the call left in that same OS thread's native
    -- error state, zero for none.
  , nativeCurrentWakeMark ∷ IO WakeMark
    -- ^ The wake mark of the call running on the calling OS thread, or zero.
  , nativeSetWindowTitle ∷ Ptr NativeWindow → Text → IO ()
  , nativeSetWindowSize ∷ Ptr NativeWindow → Int32 → Int32 → IO ()
    -- ^ The content area's logical width and height.
  , nativeSetWindowPosition ∷ Ptr NativeWindow → Int32 → Int32 → IO ()
    -- ^ The content area's upper-left corner in desktop screen coordinates.
  , nativeSetWindowSizeLimits ∷ Ptr NativeWindow → Int32 → Int32 → Int32 → Int32 → IO ()
    -- ^ The minimum width and height, then the maximum width and height.
  , nativeSetWindowAspectRatio ∷ Ptr NativeWindow → Maybe (Int32, Int32) → IO ()
    -- ^ A numerator and denominator; 'Nothing' clears the ratio.
  , nativeShowWindow ∷ Ptr NativeWindow → IO ()
  , nativeHideWindow ∷ Ptr NativeWindow → IO ()
  , nativeFocusWindow ∷ Ptr NativeWindow → IO ()
  , nativeRequestWindowAttention ∷ Ptr NativeWindow → IO ()
  , nativeIconifyWindow ∷ Ptr NativeWindow → IO ()
  , nativeMaximizeWindow ∷ Ptr NativeWindow → IO ()
  , nativeRestoreWindow ∷ Ptr NativeWindow → IO ()
  , nativeWindowMonitor ∷ Ptr NativeWindow → IO (Ptr NativeMonitor)
    -- ^ The monitor a fullscreen window is on; null for any other window.
  , nativeSetWindowMonitor ∷ Ptr NativeWindow → Ptr NativeMonitor → Int32 → Int32 → Int32 → Int32 → Maybe Int32 → IO ()
    -- ^ Put the window on a monitor, or, given null, take it off any monitor at
    -- this content position: the position, then the width and height, then the
    -- refresh rate, 'Nothing' for @GLFW_DONT_CARE@.
  , nativeSetWindowDecorated ∷ Ptr NativeWindow → Bool → IO ()
  , nativeClearWindowSizeLimits ∷ Ptr NativeWindow → IO ()
    -- ^ Every size limit @GLFW_DONT_CARE@.
  , nativeWindowCapabilities ∷ Backend → WindowCapabilities
    -- ^ What windows cannot do or report on a backend.
  , nativePlatformError ∷ !Int
    -- ^ The error code of an expected platform failure: @GLFW_PLATFORM_ERROR@.
  , nativeFeatureUnavailable ∷ !Int
    -- ^ The error code a query reports for a property this platform cannot
    -- provide: @GLFW_FEATURE_UNAVAILABLE@.
  , nativeMonitor ∷ !MonitorNative
    -- ^ The monitor operations the session's inventory performs.
  }

-- | Which session, if any, holds a native library's process-wide state.
--
-- It holds only occupancy and poison, and nothing about the session holding it.
newtype Guard = Guard (IORef Occupancy)
  deriving (Eq)

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
  , sessionTrace ∷ !Trace
    -- ^ Bounded, record-only measurement storage
    -- ("Hetoimasia.GLFW.Internal.Trace"), stopped unless an explicitly
    -- activated probe starts it. Nothing in the session, the window model, or
    -- the runtime ever starts it, and a stopped trace costs one 'IORef' read
    -- wherever it is offered a record.
  , sessionLive ∷ !(IORef Bool)
  , sessionIdentity ∷ !Unique
    -- ^ Distinguishes this session's windows from any other session's.
  , sessionWindows ∷ !(IORef Natural)
    -- ^ The next window's local identity. Never reissued.
  , sessionTeardown ∷ !(IORef Bool)
    -- ^ Cleared once any teardown, a window's included, could not establish
    -- that native ownership and callback registration ended safely.
  , sessionMonitors ∷ !Monitors
    -- ^ The monitor inventory, its identities, and its callback's latch.
  , sessionCapabilities ∷ !WindowCapabilities
    -- ^ What windows cannot do or report on the selected backend.
  , sessionClaims ∷ !(IORef MonitorClaims)
    -- ^ The fullscreen claims on the current monitors, by window.
  , sessionWakes ∷ !SessionWake
    -- ^ The capability that wakes this session's owner.
  , sessionWakeHealth ∷ !(TVar WakePath)
    -- ^ Whether this session's wake path has degraded, and how its one
    -- diagnostic report went. Every host over this session shares it.
  , sessionNotifying ∷ !(TVar Int)
    -- ^ Notifications of "Hetoimasia.GLFW.Internal.Notify" that have entered
    -- their wake call and not yet recorded what it left. A boundary that finds
    -- this at zero has seen every degradation the notifications so far caused.
  }

-- | The capability to wake one session's owner from any thread. It holds no
-- native handle and no way back to the session; once its session has closed it
-- is terminal forever.
data SessionWake = SessionWake
  { wakeNative ∷ !Native
  , wakeCapture ∷ !Capture
  , wakeGate ∷ !(TVar WakeGate)
  }

-- | Whether wake calls may enter GLFW, and how many have been admitted and not
-- yet left.
data WakeGate
  = WakeOpen !Int
  | WakeClosing !Int
  | WakeClosed

-- | What one wake call did.
data WakeOutcome
  = WakePosted
    -- ^ The empty event was posted, and nothing was reported during the call.
  | WakeTerminal
    -- ^ The session has begun closing, or has closed: GLFW was not entered.
  | WakeFailed !Reports
    -- ^ An expected platform failure: every report recorded for this call alone
    -- is @GLFW_PLATFORM_ERROR@, none was lost or faulted, and the error the call
    -- left behind, if any, is that same code. Any other evidence is raised
    -- instead; see 'wakeSession'.
  deriving (Eq, Show)

-- | Whether a session's wake path still posts, and the evidence and reporting
-- state of the expected platform failure that degraded it.
--
-- The session owns one of these. It is not the wake capability's own state:
-- 'wakeSession' classifies one call and chooses no policy, while this records
-- the policy every notifier over the session then follows.
data WakePath
  = WakePathHealthy
    -- ^ Notifications post.
  | WakePathDegraded !Reports !DegradationReport
    -- ^ An expected platform failure degraded the path, with the evidence
    -- attributed to the call that failed. Nothing posts afterwards; the owner's
    -- finite idle wait is the bounded fallback.
  deriving (Eq, Show)

-- | How the degradation's one diagnostic report went. It is claimed once, at a
-- safe owner boundary, and never retried, whatever it records.
data DegradationReport
  = DegradationOwed
    -- ^ No attempt has been claimed yet.
  | DegradationReporting
    -- ^ An attempt is in progress.
  | DegradationReported
    -- ^ The attempt completed. The logger may have filtered the entry; the
    -- attempt is spent either way.
  | DegradationReportFailed
    -- ^ The attempt's sink failed. The failure propagated to the owner.
  | DegradationReportInterrupted
    -- ^ The attempt was cancelled. The cancellation propagated to the owner.
  deriving (Eq, Show)

-- | The session's wake capability.
sessionWake ∷ Session → SessionWake
sessionWake = sessionWakes

-- | The session's wake-path state, which every notifier and every host over
-- this session shares. A later session has its own, so degradation never
-- carries across sessions.
sessionWakePath ∷ Session → TVar WakePath
sessionWakePath = sessionWakeHealth

-- | How many of the session's notifications are inside their wake call, with
-- what it left still unrecorded. A notification leaves this count only after
-- recording whatever degradation it found, so a boundary that waits for zero
-- cannot miss one.
sessionNotificationsInFlight ∷ Session → TVar Int
sessionNotificationsInFlight = sessionNotifying

-- | The backend the session initialized.
sessionBackend ∷ Session → Backend
sessionBackend = sessionSelected

-- | What windows in the session cannot do or report on its backend. Any thread
-- may ask; it never changes during the session.
sessionWindowCapabilities ∷ Session → WindowCapabilities
sessionWindowCapabilities = sessionCapabilities

-- | What GLFW 3.4 windows cannot do or report on a backend. X11 and Cocoa
-- perform every ordinary control and report every attribute a window observes.
--
-- The Wayland row is audited against the pinned GLFW 3.4 Wayland backend for
-- every 'WindowOperation' and every 'WindowReport'; the capabilities table in
-- @docs/glfw.md@ records that audit with GLFW's own answer cited per entry.
-- Three operations and two attributes are the whole of what GLFW answers
-- unavailable within this vocabulary: it gives clients no global position to
-- set or read, and so cannot place a borderless window over a monitor's work
-- area, lets only the compositor move input focus, and reports no iconified
-- state at all. The other operations GLFW answers unavailable on Wayland — the
-- window icon, floating, opacity, and the cursor position — are outside this
-- vocabulary, so the audit adds none of them. Nothing here is emulated, and a
-- restriction GLFW does not report is not invented.
backendWindowCapabilities ∷ Backend → WindowCapabilities
backendWindowCapabilities = \case
  Wayland →
    windowCapabilities
      [ (SetPositionOperation, noGlobalPosition)
      , (FocusOperation, "Wayland lets only the compositor move input focus")
      , (BorderlessOperation, noGlobalPosition)
      ]
      [ (PlacementReport, noGlobalPosition)
      , (IconifiedReport, "Wayland reports no iconified state; GLFW always answers false")
      ]
  X11 → fullWindowCapabilities
  Cocoa → fullWindowCapabilities
  where
    noGlobalPosition = "Wayland gives clients no global window position"

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

attachMonitorOperation, detachMonitorOperation ∷ Operation
attachMonitorOperation = operation "attach monitor callback"
detachMonitorOperation = operation "detach monitor callback"

synchronizeMonitorsOperation, reconcileMonitorsOperation, resolveMonitorOperation ∷ Operation
synchronizeMonitorsOperation = operation "synchronize monitors"
reconcileMonitorsOperation = operation "reconcile monitor events"
resolveMonitorOperation = operation "resolve monitor"

wakeOperation ∷ Operation
wakeOperation = operation "wake session"

takeReportsOperation, createWindowOperation, destroyWindowOperation ∷ Operation
takeReportsOperation = operation "take asynchronous reports"
createWindowOperation = operation "create window"
destroyWindowOperation = operation "destroy window"

backendIdentifiers ∷ Backend → [(Text, Text)]
backendIdentifiers backend = [("backend", backendText backend)]

-- | Construct a session over a native table.
--
-- Resolution, support, initialization, and verification are four distinct
-- answers, and each keeps its own evidence. A backend the platform does not
-- admit is 'UnsupportedBackend' at resolution; a backend the prefix was built
-- without is 'UnsupportedBackend' at the support check, still before any
-- native mutation. A supported answer says only that the backend is compiled
-- in, never that its display or socket can be reached: that is settled by
-- 'glfwInit', whose failure is a 'NativeFailure' carrying GLFW's own reports,
-- so an unreachable display is identified by the report's code and description
-- rather than by a separate outcome. Only once initialization succeeds does
-- 'glfwGetPlatform' decide whether the backend actually selected is the one
-- admitted, and a mismatch is 'BackendNotSelected'.
--
-- The stages and their releases:
--
-- +-----------------------------+------------------------------+---------------+
-- | Stage                       | Release                      | Release order |
-- +=============================+==============================+===============+
-- | Resolve backend, check      | none                         |               |
-- | thread                      |                              |               |
-- +-----------------------------+------------------------------+---------------+
-- | Claim the guard             | Vacate, or poison            | seventh       |
-- +-----------------------------+------------------------------+---------------+
-- | Query platform support      | none                         |               |
-- +-----------------------------+------------------------------+---------------+
-- | Install the error callback  | Detach, then free if safe    | fifth         |
-- +-----------------------------+------------------------------+---------------+
-- | Set hints and initialize    | Terminate                    | fourth        |
-- +-----------------------------+------------------------------+---------------+
-- | Raise initialization        | none                         |               |
-- | reports; verify the backend |                              |               |
-- +-----------------------------+------------------------------+---------------+
-- | Allocate the monitor        | Free if safe                 | sixth         |
-- | callback's storage          |                              |               |
-- +-----------------------------+------------------------------+---------------+
-- | Attach the monitor callback | Take a latched fault; detach | third         |
-- +-----------------------------+------------------------------+---------------+
-- | Sample the initial monitor  | none                         |               |
-- | inventory                   |                              |               |
-- +-----------------------------+------------------------------+---------------+
-- | Publish the inventory       | End every identity; close    | second        |
-- |                             | the snapshot holding the     |               |
-- |                             | last descriptions            |               |
-- +-----------------------------+------------------------------+---------------+
-- | Open the wake gate          | Close it; wait for admitted  | first         |
-- |                             | wake calls to leave          |               |
-- +-----------------------------+------------------------------+---------------+
sessionAssembly ∷ Native → SessionConfig → Assembly Session
sessionAssembly native config = do
  backend ← restoredStep (admit native config)
  owner ← restoredStep myThreadId
  teardown ← restoredStep (newIORef True)
  live ← restoredStep (newIORef True)
  identity ← restoredStep newUnique
  windows ← restoredStep (newIORef 1)
  claims ← restoredStep (newIORef Map.empty)
  capture ← restoredStep (newCapture (nativeIsProcessMainThread native) (nativeCurrentWakeMark native))
  trace ← restoredStep newTrace
  health ← restoredStep (newTVarIO WakePathHealthy)
  notifying ← restoredStep (newTVarIO 0)
  acquirePart
    "glfw session occupancy"
    (releaseRank 6)
    (claimGuard (nativeGuard native) backend)
    (\() → settleGuard (nativeGuard native) teardown)
  restoredStep (requireSupported native backend)
  _ ←
    acquirePart
      "glfw error callback"
      (releaseRank 4)
      (attachCallback native capture teardown)
      (detachCallback native capture owner teardown)
  initialized ←
    acquirePart
      "glfw terminate"
      (releaseRank 3)
      (initialize native capture teardown backend)
      (\_ → terminate native capture owner teardown live backend)
  restoredStep $ do
    raiseReported initializeOperation (backendIdentifiers backend) NativeCallReturned initialized
    verifySelected native capture backend
  source ←
    restoredStep (newMonitorSource (nativeMonitor native) capture (nativeFeatureUnavailable native) identity)
  storage ←
    acquirePart
      "glfw monitor callback storage"
      (releaseRank 5)
      (nativeNewMonitorCallback (nativeMonitor native) (monitorCallback source))
      (freeMonitorCallback native teardown)
  -- The detach is registered before the callback is attached, so an attachment
  -- that reported an error, raised, or was interrupted is detached before
  -- termination.
  acquirePart
    "glfw monitor callback"
    (releaseRank 2)
    (pure ())
    (\() → detachMonitorCallback native capture owner teardown source)
  restoredStep (attachMonitorCallback native capture teardown storage)
  initial ← restoredStep (sampleInitialInventory source)
  cell ← restoredStep (newMonitorCell initial)
  publisher ←
    acquirePart
      "glfw monitor inventory"
      (releaseRank 1)
      (publishInitialInventory initial)
      (closeInventory cell)
  gate ←
    acquirePart
      "glfw wake gate"
      (releaseRank 0)
      (newTVarIO (WakeOpen 0))
      closeWakeGate
  pure
    Session
      { sessionNative = native
      , sessionOwner = owner
      , sessionSelected = backend
      , sessionCapture = capture
      , sessionTrace = trace
      , sessionLive = live
      , sessionIdentity = identity
      , sessionWindows = windows
      , sessionTeardown = teardown
      , sessionMonitors = assembleMonitors source cell publisher
      , sessionCapabilities = nativeWindowCapabilities native backend
      , sessionClaims = claims
      , sessionWakes = SessionWake native capture gate
      , sessionWakeHealth = health
      , sessionNotifying = notifying
      }

admit ∷ Native → SessionConfig → IO Backend
admit native config = do
  backend ←
    either
      (throwFailure glfwComponent enterSession requestIdentifiers)
      pure
      (resolveBackend (nativeHostBackend native) (nativeAdmittedBackends native) (requestedBackend config))
  bound ← isCurrentThreadBound
  onMain ← nativeIsProcessMainThread native
  unless (bound && onMain) $
    throwFailure glfwComponent enterSession (backendIdentifiers backend) NotProcessMainThread
  pure backend
  where
    requestIdentifiers = maybe [] backendIdentifiers (requestedBackend config)

-- | Resolve a request against the platform's default and the backends it
-- admits. An absent request takes the default; a request naming an admitted
-- backend is taken as asked. Nothing else resolves, and no resolution ever
-- answers a backend other than the one asked for, so no request falls back.
resolveBackend ∷ Maybe Backend → [Backend] → Maybe Backend → Either UnsupportedBackend Backend
resolveBackend platform admitted request =
  case request of
    Nothing
      | Just fallback ← platform
      , fallback `elem` admitted →
          Right fallback
    Just wanted
      | wanted `elem` admitted → Right wanted
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

attachMonitorCallback ∷ Native → Capture → IORef Bool → MonitorCallbackStorage → IO ()
attachMonitorCallback native capture teardown storage = do
  settleStrayOwnerReports capture
  -- An attachment that raises may have registered the callback, so its storage
  -- is never freed and the guard is poisoned.
  nativeAttachMonitorCallback (nativeMonitor native) storage `onException` atomicWriteIORef teardown False
  reports ← takeOwnerReports capture
  raiseReported attachMonitorOperation [] NativeCallReturned reports

-- | Detach the monitor callback before termination. A fault latched since the
-- last boundary is taken first, so no detach outcome can abandon it: after a
-- detach that succeeded it is raised on its own, and beside a detach that failed
-- it is retained as a labelled cleanup failure while the detach's failure stays
-- primary.
detachMonitorCallback ∷ Native → Capture → ThreadId → IORef Bool → MonitorSource → IO ()
detachMonitorCallback native capture owner teardown source = do
  pending ← takeMonitorFault source
  detached ∷ Either (ExceptionWithContext SomeException) () ←
    tryWithContext $
      ownerRelease owner teardown detachMonitorOperation $ do
        settleStrayOwnerReports capture
        nativeDetachMonitorCallback (nativeMonitor native) `onException` atomicWriteIORef teardown False
        reports ← takeOwnerReports capture
        raiseReported detachMonitorOperation [] NativeCallReturned reports
  case (detached, pending) of
    (Right (), Nothing) → pure ()
    (Right (), Just fault) → rethrowMonitorFault fault
    (Left failure, Nothing) → rethrowIO failure
    (Left failure, Just fault) →
      withResourceLabelled
        "glfw monitor callback fault"
        (pure ())
        (\() → rethrowMonitorFault fault)
        (\() → rethrowIO failure)

-- | Free the monitor callback's storage after the session's final native use,
-- only if every teardown step so far ended safely; otherwise keep it.
freeMonitorCallback ∷ Native → IORef Bool → MonitorCallbackStorage → IO ()
freeMonitorCallback native teardown storage = do
  safe ← readIORef teardown
  when safe (nativeFreeMonitorCallback (nativeMonitor native) storage)

-- | Close the wake gate to new calls, then wait until every admitted call has
-- left. The wait is uninterruptible, because every release after this one
-- depends on no wake call being inside GLFW; it is bounded by one empty-event
-- post per admitted call, and nothing else can hold a call inside.
closeWakeGate ∷ TVar WakeGate → IO ()
closeWakeGate gate = uninterruptibleMask_ $ do
  atomically $
    readTVar gate >>= \case
      WakeOpen admitted → writeTVar gate (WakeClosing admitted)
      _ → pure ()
  atomically $
    readTVar gate >>= \case
      WakeClosing 0 → writeTVar gate WakeClosed
      WakeClosing _ → retry
      _ → pure ()

-- | Wake the owner of the capability's session: post one empty event so a
-- native wait in progress, or the next one, returns.
--
-- Any thread may call it, bound or unbound, including the owner. It answers
-- 'WakeTerminal' without entering GLFW once the session has begun closing.
--
-- An error reported during the call is attributed to this call alone; it is
-- neither left among the session's asynchronous reports nor taken from them or
-- from a concurrent owner operation. The evidence is then classified. Only an
-- expected platform failure — every recorded report @GLFW_PLATFORM_ERROR@, none
-- lost or faulted, and the error the call left in its thread's native error
-- state either that code or none — is answered as the ordinary 'WakeFailed'.
-- Anything else — another code, such as @GLFW_NOT_INITIALIZED@, a report lost
-- to the bound, a callback fault, or an error the call left that no report
-- recorded — is a programming or lifetime violation, or evidence that cannot be
-- classified, and is raised as a 'NativeFailure' attributed to @wake session@,
-- carrying the call's reports with an unrecorded error counted as a callback
-- fault. So lost evidence is never a successful wake, and never a recoverable
-- one. A native table that raises propagates its exception. Either way the
-- call's accounting has settled first. The wake does not retry, and does not
-- decide what an expected failure means.
wakeSession ∷ SessionWake → IO WakeOutcome
wakeSession wake = mask_ $ do
  admitted ← atomically (enterWake (wakeGate wake))
  if not admitted
    then pure WakeTerminal
    else
      flip finally (uninterruptibleMask_ (atomically (leaveWake (wakeGate wake)))) $ do
        mark ← beginWakeReports capture
        code ← nativePostEmptyEvent (wakeNative wake) mark `onException` takeWakeReports capture mark
        reports ← takeWakeReports capture mark
        classifyWake (nativePlatformError (wakeNative wake)) code reports
  where
    capture = wakeCapture wake

-- | Classify what one wake call left: nothing is a posted wake, evidence of only
-- the platform error is an expected failure, and anything else is raised.
classifyWake ∷ Int → Int → Reports → IO WakeOutcome
classifyWake platformError code reports
  | not (hasReports evidence) = pure WakePosted
  | expected = pure (WakeFailed evidence)
  | otherwise = throwFailure glfwComponent wakeOperation [] (NativeFailure NativeCallReturned evidence)
  where
    recorded = reportedErrors reports
    -- An error the call left with no evidence at all; a lost report or a
    -- callback fault already accounts for one that was not recorded.
    unrecorded = code /= 0 && not (hasReports reports)
    evidence
      | unrecorded = reports {callbackFaults = callbackFaults reports + 1}
      | otherwise = reports
    expected =
      not (null recorded)
        && all ((== platformError) . nativeErrorCode) recorded
        && reportsLost reports == 0
        && callbackFaults reports == 0
        && (code == 0 || code == platformError)

-- | Admit one wake call if the gate is open. Never retries.
enterWake ∷ TVar WakeGate → STM Bool
enterWake gate =
  readTVar gate >>= \case
    WakeOpen admitted → True <$ writeTVar gate (WakeOpen (admitted + 1))
    _ → pure False

-- | Account for an admitted call that has left. Never retries.
leaveWake ∷ TVar WakeGate → STM ()
leaveWake gate =
  readTVar gate >>= \case
    WakeOpen admitted → writeTVar gate (WakeOpen (admitted - 1))
    WakeClosing admitted → writeTVar gate (WakeClosing (admitted - 1))
    WakeClosed → pure ()

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

-- | Issue the next local window identity. Identities start at one and are never
-- reissued within a session.
nextWindowIdentity ∷ Session → IO Natural
nextWindowIdentity session =
  atomicModifyIORef' (sessionWindows session) (\next → (next + 1, next))

-- | Refuse an operation on a session whose teardown safety has already been
-- lost, with the misuse a later entry would see.
requireUnpoisoned ∷ Session → Operation → [(Text, Text)] → IO ()
requireUnpoisoned session operationName identifiers = do
  safe ← readIORef (sessionTeardown session)
  unless safe $
    throwFailure glfwComponent operationName identifiers SessionPoisoned

-- | Record that a teardown could not establish it ended safely. The session
-- refuses further windows, keeps its error callback storage, and poisons the
-- guard when it ends.
poisonSession ∷ Session → IO ()
poisonSession session = atomicWriteIORef (sessionTeardown session) False

-- | The read endpoint of the session's monitor inventory. Any thread may read
-- it, and it stays readable after the session ends, holding the closed
-- inventory.
monitorInventory ∷ Session → SnapshotReader MonitorInventory
monitorInventory = monitorsReader . sessionMonitors

-- | Refresh the monitor inventory at an owner boundary, publishing a new
-- revision if a description or an identity changed, and answer the current
-- inventory.
synchronizeMonitors ∷ Session → IO MonitorInventory
synchronizeMonitors session =
  ownerOperation session synchronizeMonitorsOperation [] (refreshMonitors session)

-- | Refresh the monitor inventory only if the monitor callback captured a change
-- since the last refresh: the owner loop's step after native events.
reconcileMonitorEvents ∷ Session → IO ()
reconcileMonitorEvents session =
  ownerOperation session reconcileMonitorsOperation [] $
    reconcileInventory (sessionMonitors session) `finally` pruneSessionClaims session

-- | Re-resolve a monitor identity against the monitors GLFW reports now, and
-- answer its fresh description, or 'MonitorDisconnected' for an identity whose
-- connection has ended or that belongs to another session.
resolveMonitor ∷ Session → MonitorId → IO (MonitorResult MonitorDescription)
resolveMonitor session identity =
  ownerOperation session resolveMonitorOperation (monitorIdentifiers identity) $
    resolveMonitorPointer session identity >>= \case
      MonitorAvailable (description, _) → pure (MonitorAvailable description)
      MonitorDisconnected ended → pure (MonitorDisconnected ended)

-- | Run one monitor-targeted native operation at an owner boundary: the identity
-- is re-resolved immediately before it, the operation receives the live pointer
-- that resolution's enumeration returned, and errors reported during it fail
-- it. An ended identity answers 'MonitorDisconnected' without running it. The
-- pointer must not escape the operation.
withResolvedMonitor ∷ Session → Operation → MonitorId → (Ptr NativeMonitor → IO a) → IO (MonitorResult a)
withResolvedMonitor session operationName identity action =
  ownerOperation session operationName identifiers $
    resolveMonitorPointer session identity >>= \case
      MonitorDisconnected ended → pure (MonitorDisconnected ended)
      MonitorAvailable (_, pointer) → do
        settleStrayOwnerReports capture
        value ← action pointer
        reports ← takeOwnerReports capture
        raiseReported operationName identifiers NativeCallReturned reports
        pure (MonitorAvailable value)
  where
    capture = sessionCapture session
    identifiers = monitorIdentifiers identity

-- | The session's fullscreen monitor claims, read on the owner thread.
monitorClaims ∷ Session → IO MonitorClaims
monitorClaims session =
  ownerOperation session (operation "read monitor claims") [] (readIORef (sessionClaims session))

-- | The monitor identities the last committed refresh observed. The caller is
-- already inside an owner operation.
liveMonitors ∷ Session → IO [MonitorId]
liveMonitors = liveIdentities . sessionMonitors

-- | The current inventory's monitors, without a refresh. The caller is already
-- inside an owner operation.
currentSessionMonitors ∷ Session → IO (Attribute [MonitorDescription])
currentSessionMonitors = currentMonitors . sessionMonitors

-- | The identity of the monitor pointer a window query just returned. The caller
-- is already inside an owner operation.
identifyWindowMonitor ∷ Session → Ptr NativeMonitor → IO (Attribute (Maybe MonitorId))
identifyWindowMonitor = identifyPointer . sessionMonitors

-- | Refresh the inventory and answer it. The caller is already inside an owner
-- operation.
refreshMonitors ∷ Session → IO MonitorInventory
refreshMonitors session = synchronizeInventory (sessionMonitors session) `finally` pruneSessionClaims session

-- | Refresh the inventory and answer the identity's description and the live
-- pointer this boundary's enumeration returned, which must not outlive the
-- calling boundary. The caller is already inside an owner operation.
resolveMonitorPointer ∷ Session → MonitorId → IO (MonitorResult (MonitorDescription, Ptr NativeMonitor))
resolveMonitorPointer session identity = resolveInventory (sessionMonitors session) identity `finally` pruneSessionClaims session

-- | Drop the claims of identities the inventory no longer holds: every refresh
-- and resolution does, whether it returns or rethrows a monitor callback fault
-- after committing, so a disconnected monitor's claim ends with its identity.
-- Pruning against identities a failed refresh left unchanged changes nothing.
pruneSessionClaims ∷ Session → IO ()
pruneSessionClaims session = do
  live ← liveIdentities (sessionMonitors session)
  atomicModifyIORef' (sessionClaims session) (\claims → (pruneClaims live claims, ()))

monitorIdentifiers ∷ MonitorId → [(Text, Text)]
monitorIdentifiers identity = [("monitor", Text.pack (show (monitorLocalIdentity identity)))]
