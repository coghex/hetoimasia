-- | The test seam's implementation: the real GLFW session and window models
-- over a scripted native library, and the private window drivers.
--
-- This module belongs to the private @seam-core@ sublibrary. No package outside
-- @hetoimasia-glfw@ can import it. The public "Hetoimasia.GLFW.Seam" re-exports
-- everything here except the window drivers — 'seamDrive',
-- 'seamDriveCancelledBeforeCommit', 'seamRejectCloseRequest', and
-- 'seamSetModeTransition' — which only the package's own
-- @glfw-tests@ suite uses.
--
-- A 'Seam' is a native table that initializes nothing. It records every native
-- operation the session model asks for as a 'NativeCall', answers each from a
-- 'SeamScript', and invokes the error callback the model installed when a
-- scripted step reports an error. The model itself — entry order, thread
-- checks, exclusivity, attribution, rollback, and poisoning — is the production
-- code, not a copy of it.
--
-- Thread identity is scripted as well. A seam treats as the process main
-- thread only the Haskell threads designated with
-- 'designateProcessMainThread'; 'asProcessMainThread' runs an action in a
-- bound thread designated that way. Boundness is the runtime's own answer, so
-- an unbound designated thread and an undesignated bound worker are both
-- rejected, each for its own reason.
--
-- Each seam has its own guard, so examples never share occupancy with each
-- other or with a production session.
--
-- A wake's empty-event post is recorded as 'PostEmptyEvent' and runs the
-- script's 'scriptPostEmptyEvent' step on the calling thread. While that step
-- runs the calling thread's wake mark is the call's, so an error the step
-- reports through 'reportError' is attributed to that wake call, as GLFW's
-- callback attributes one on the posting OS thread. The seam also keeps, per
-- calling thread, the last code a step reported, and the post answers the code
-- its own step left, as the binding answers the thread's GLFW error state.
-- 'reportErrorWithFailingWakeMark' reports while the wake mark cannot be read.
--
-- Windows are created through the public "Hetoimasia.GLFW.Window" interface
-- in a seam session. The seam hands each a scripted native handle, keeps the
-- callbacks the model attached to it, and delivers scripted 'WindowEvent's to
-- them from inside an owner-boundary step, as GLFW would from inside a setter
-- or a poll: 'seamDrive'. 'seamQueueEvents' instead leaves events for the next
-- poll or finite wait an owner turn makes, which delivers them from inside that
-- native call. 'seamRejectCloseRequest' is the private close-request
-- transition, and 'seamSetModeTransition' sets or clears the window's private
-- mode transition marker, which only a mode transition would otherwise set.
--
-- Every ordinary control call the window model makes is recorded — its window
-- key and its arguments in native types — and runs the script's
-- 'scriptWindowControl' step, which may report errors. The script's
-- 'scriptWindowCapabilities' describes what windows cannot do or report on the
-- session's backend, so an example can model a platform no session selects. None of them is a public command, and none is exported by the
-- public seam. Each also refuses, with 'ForeignSeamWindow' and before anything
-- else, a window whose session was not entered over this seam's own native
-- table.
--
-- The seam's private command executor drives the window command protocol of
-- "Hetoimasia.GLFW.Internal.Command" — admission, FIFO claim, protected
-- execution and settlement, and closure — over seam windows on the CPU:
-- 'seamExecuteNext' executes the oldest queued command against the windows it
-- is given, 'seamExecuteNextInterrupted' delivers an interruption immediately
-- after the claim, and 'seamExecuteNextScripted' replaces the execution with a
-- scripted one, for simulated effects and completion data that fails to
-- prepare. It is a test seam, not a second production executor; with the
-- admission hooks re-exported beside it, it is private to this package in the
-- same way as the window drivers.
--
-- Monitors are scripted as a 'MonitorTopology': the enumeration the seam's
-- native table answers, keyed by the scripted address each monitor's pointer
-- stands for, and which address is primary. 'seamSetMonitorTopology' changes
-- it, 'seamDeliverMonitorEvents' invokes the attached monitor callback at once
-- on the calling thread, and 'seamQueueMonitorEvents' leaves events for the
-- next poll or finite wait to deliver from inside that call. Like the window
-- drivers, they are private to this sublibrary.
--
-- Mode steps are recorded like controls — setting a window's monitor, its
-- decoration, and clearing its size limits — and run 'scriptWindowControl' too.
-- The seam keeps each window's decoration and monitor, which a step that reported
-- no error changes, and GLFW's own handling of a disconnected monitor: delivering
-- its disconnection takes every window on it off the monitor at the desktop
-- origin. With 'scriptTrackWindows' it also keeps each window's size and position,
-- answering queries from them instead of the script: creation starts a window at
-- its requested size at (40, 30), a setter or a delivered move or resize changes
-- them, and a fullscreen window takes its monitor's position and mode size.
-- Whatever the tracking, a window put on a monitor sets that monitor's current
-- video mode to its size and, when one is given, refresh rate, and the monitor's
-- previous mode is restored once the window leaves it or is destroyed, as GLFW
-- does.
--
-- The seam exposes no native handle and no session or window constructor.
module Hetoimasia.GLFW.Internal.Seam
  ( -- * Seams
    Seam
  , newSeam
  , SeamScript (..)
  , defaultScript
  , seamSession
  , seamCalls
  , seamLiveCallbacks
  , seamLiveWindowCallbacks
  , seamLiveMonitorCallbacks
  , featureUnavailableCode

    -- * Scripted monitors
  , MonitorTopology (..)
  , ScriptedMonitor (..)
  , NativeVideoMode (..)
  , MonitorQuery (..)
  , noMonitors
  , scriptedMonitor

    -- * Driving monitors
  , SeamMonitorEvent (..)
  , seamSetMonitorTopology
  , seamDeliverMonitorEvents
  , seamQueueMonitorEvents

    -- * Driving windows
  , WindowEvent (..)
  , DriveOrigin (..)
  , seamDrive
  , seamDriveWith
  , seamDriveCancelledBeforeCommit
  , seamQueueEvents
  , seamQueueControlEvents
  , seamRejectCloseRequest
  , seamSetModeTransition
  , ForeignSeamWindow (..)

    -- * Executing window commands
  , ExecutionStep (..)
  , seamExecuteNext
  , seamExecuteNextInterrupted
  , seamExecuteNextScripted
  , AdmissionHooks (..)
  , noAdmissionHooks
  , submitWith
  , awaitSubmitWith

    -- * Thread identity
  , asProcessMainThread
  , designateProcessMainThread

    -- * Reporting errors from a scripted step
  , Reporter
  , reportError
  , reportErrorFromOtherThread
  , reportErrorWithFailingIdentity
  , reportErrorWithFailingWakeMark

    -- * What the model asked of the native library
  , NativeCall (..)
  , WindowHint (..)
  , WindowAttribute (..)
  ) where

import Control.Concurrent (ThreadId, forkIO, myThreadId, runInBoundThread)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Exception (AsyncException (ThreadKilled), Exception, SomeException, finally, throw, throwIO, try)
import Control.Monad (forM_, unless, when)
import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import Data.IORef (IORef, atomicModifyIORef', atomicWriteIORef, newIORef, readIORef)
import Data.Int (Int32)
import Data.Text (Text)
import Foreign.C.Types (CFloat, CInt)
import Foreign.Ptr (Ptr, castFunPtrToPtr, castPtrToFunPtr, intPtrToPtr, nullPtr, ptrToIntPtr)
import Hetoimasia.Foundation.Failure (operation)
import Hetoimasia.Foundation.Resource (Scoped, allocComposite)
import Hetoimasia.GLFW.Internal.Capture (ErrorCallback, WakeMark, noWakeMark)
import Hetoimasia.GLFW.Internal.Control (WindowCapabilities)
import Hetoimasia.GLFW.Internal.Command
  ( AdmissionHooks (..)
  , CommandOrigin
  , CommandRejection
  , CommandResult
  , Execution (..)
  , ExecutionStep (..)
  , WindowCommand
  , WindowCommandHost
  , awaitSubmitWith
  , commandHostSession
  , executeCommand
  , executeNextWith
  , noAdmissionHooks
  , submitWith
  )
import Hetoimasia.GLFW.Internal.Monitor
  ( MonitorCallback
  , MonitorCallbackStorage (MonitorCallbackStorage)
  , MonitorNative (..)
  , NativeMonitor
  , NativeVideoMode (..)
  )
import Hetoimasia.GLFW.Internal.Session
  ( Backend (..)
  , CallbackStorage (CallbackStorage)
  , Guard
  , Native (..)
  , NativeWindow
  , Session
  , SessionConfig
  , WindowAttribute (..)
  , WindowCallbackStorage (WindowCallbackStorage)
  , WindowCallbacks (..)
  , WindowHint (..)
  , backendWindowCapabilities
  , newGuard
  , sessionAssembly
  , sessionNative
  )
import Hetoimasia.GLFW.Internal.Window
  ( CloseRequest
  , Window
  , WindowResult
  , rejectCloseRequest
  , setModeTransition
  , windowNativeHandle
  , windowSession
  , windowStepWith
  )

-- | One native operation the model asked for, in the order it asked.
data NativeCall
  = QueryPlatformSupported Backend
  | CreateErrorCallback
  | AttachErrorCallback
  | DetachErrorCallback
  | FreeErrorCallback
  | SetInitHints Backend
  | Initialize
  | QueryPlatform
  | Terminate
  | ResetWindowHints
  | SetWindowHint WindowHint
  | CreateWindow Int32 Int32 Text
    -- ^ Answered with the next window key, starting at one.
  | DestroyWindow Int
  | CreateWindowCallbacks
  | AttachWindowCallbacks Int
  | DetachWindowCallbacks Int
  | FreeWindowCallbacks
  | QueryWindowSize
  | QueryFramebufferSize
  | QueryContentScale
  | QueryWindowPosition
  | QueryWindowAttribute WindowAttribute
  | PollEvents
  | WaitEvents Double
    -- ^ A finite wait, with its bound in seconds.
  | PostEmptyEvent
    -- ^ A wake's cross-thread empty-event post, from whichever thread made it.
  | CreateMonitorCallback
  | AttachMonitorCallback
  | DetachMonitorCallback
  | FreeMonitorCallback
  | QueryMonitors
  | QueryPrimaryMonitor
  | QueryMonitor Int MonitorQuery
    -- ^ A query targeting the monitor at a scripted address.
  | SetWindowTitle Int Text
    -- ^ An ordinary control of the window with this key, and each below.
  | SetWindowSize Int Int32 Int32
  | SetWindowPosition Int Int32 Int32
  | SetWindowSizeLimits Int Int32 Int32 Int32 Int32
    -- ^ Minimum width and height, then maximum width and height.
  | SetWindowAspectRatio Int (Maybe (Int32, Int32))
    -- ^ 'Nothing' clears the ratio.
  | ShowWindow Int
  | HideWindow Int
  | FocusWindow Int
  | RequestWindowAttention Int
  | IconifyWindow Int
  | MaximizeWindow Int
  | RestoreWindow Int
  | QueryWindowMonitor
  | SetWindowMonitor Int Int Int32 Int32 Int32 Int32 (Maybe Int32)
    -- ^ The window key, the monitor's scripted address or zero for none, the
    -- position, the size, and the refresh rate.
  | SetWindowDecorated Int Bool
  | ClearWindowSizeLimits Int
  deriving (Eq, Show)

-- | Which monitor query was made.
data MonitorQuery
  = NameQuery
  | PositionQuery
  | WorkAreaQuery
  | PhysicalSizeQuery
  | ContentScaleQuery
  | CurrentModeQuery
  | VideoModesQuery
  deriving (Eq, Show)

-- | What a scripted monitor reports, in the native table's own types, so an
-- example can script values the model must refuse.
data ScriptedMonitor = ScriptedMonitor
  { scriptedName ∷ Maybe Text
  , scriptedPosition ∷ (CInt, CInt)
  , scriptedWorkArea ∷ (CInt, CInt, CInt, CInt)
  , scriptedPhysicalSize ∷ (CInt, CInt)
  , scriptedContentScale ∷ (CFloat, CFloat)
  , scriptedCurrentMode ∷ Maybe NativeVideoMode
  , scriptedVideoModes ∷ Maybe [NativeVideoMode]
  }

-- | The monitors the scripted platform enumerates.
data MonitorTopology = MonitorTopology
  { topologyMonitors ∷ Maybe [(Int, ScriptedMonitor)]
    -- ^ By scripted address, in enumeration order. Address zero stands for a
    -- null pointer; 'Nothing' is an enumeration whose count was inconsistent.
  , topologyPrimary ∷ Int
    -- ^ The primary monitor's address; zero for none.
  }

-- | A platform with no connected monitor and no primary one.
noMonitors ∷ MonitorTopology
noMonitors = MonitorTopology (Just []) 0

-- | A consistent monitor with the given name, desktop position, and current
-- mode size: a 60 Hz, 8-bit mode that is also its only mode, a work area
-- covering it, a 600 by 340 millimetre panel, and a content scale of one.
scriptedMonitor ∷ Text → (Int, Int) → (Int, Int) → ScriptedMonitor
scriptedMonitor name (x, y) (width, height) =
  ScriptedMonitor
    { scriptedName = Just name
    , scriptedPosition = (fromIntegral x, fromIntegral y)
    , scriptedWorkArea = (fromIntegral x, fromIntegral y, fromIntegral width, fromIntegral height)
    , scriptedPhysicalSize = (600, 340)
    , scriptedContentScale = (1, 1)
    , scriptedCurrentMode = Just mode
    , scriptedVideoModes = Just [mode]
    }
  where
    mode = NativeVideoMode (fromIntegral width) (fromIntegral height) 8 8 8 60

-- | A monitor callback event the seam delivers.
data SeamMonitorEvent
  = MonitorAttached Int
    -- ^ @GLFW_CONNECTED@ for the monitor at a scripted address.
  | MonitorDetached Int
    -- ^ @GLFW_DISCONNECTED@ for the monitor at a scripted address.
  | MonitorEventCode Int CInt
    -- ^ An arbitrary event code.
  | MonitorEventRaises Int SomeException
    -- ^ An event code that raises the exception when copied.

-- | A native event the seam delivers to a window's attached callbacks.
data WindowEvent
  = ResizedTo Int Int
  | FramebufferResizedTo Int Int
  | ContentScaledTo Float Float
  | MovedTo Int Int
  | FocusChanged Bool
  | IconifyChanged Bool
  | MaximizeChanged Bool
  | RefreshRequested
  | CloseRequested
  | KeyEventAt Int Int Int Int
    -- ^ Physical key, scancode, action, and modifiers, as GLFW passes them.
  | CharEventAt Int
    -- ^ Unicode code point.
  | ButtonEventAt Int Int Int
    -- ^ Button, action, and modifiers.
  | CursorMovedTo Double Double
  | CursorEnterChanged Bool
  | ScrollEventAt Double Double
  | CallbackRaises SomeException
    -- ^ A size callback whose payload raises the exception when copied.

-- | Which kind of native call the events are delivered from inside.
data DriveOrigin
  = DuringSetter
  | DuringPoll
  deriving (Eq, Show)

-- | How the scripted native library answers.
--
-- Each step runs after its call is recorded, and may report errors through the
-- 'Reporter' it is given, or throw.
data SeamScript = SeamScript
  { scriptHostBackend ∷ Maybe Backend
    -- ^ The backend the scripted platform selects when no request names one.
  , scriptAdmittedBackends ∷ [Backend]
    -- ^ Which backends the scripted platform admits to the support check. A
    -- request naming another is refused at resolution, before any call.
  , scriptPlatformSupported ∷ Backend → Bool
    -- ^ Whether the prefix was built with the admitted backend, as
    -- @glfwPlatformSupported@ answers it.
  , scriptInitialize ∷ Reporter → IO Bool
  , scriptReportedPlatform ∷ Maybe Backend → Maybe Backend
    -- ^ What the platform query answers, given the backend last hinted.
  , scriptTerminate ∷ Reporter → IO ()
  , scriptDetachErrorCallback ∷ Reporter → IO ()
  , scriptCreateWindow ∷ Reporter → IO Bool
    -- ^ 'True' returns a live handle; 'False' returns null.
  , scriptDestroyWindow ∷ Reporter → IO ()
  , scriptAttachWindowCallbacks ∷ Reporter → IO ()
  , scriptDetachWindowCallbacks ∷ Reporter → IO ()
  , scriptWindowSize ∷ Reporter → IO (Int, Int)
  , scriptFramebufferSize ∷ Reporter → IO (Int, Int)
  , scriptContentScale ∷ Reporter → IO (Float, Float)
  , scriptWindowPosition ∷ Reporter → IO (Int, Int)
  , scriptWindowAttribute ∷ WindowAttribute → Reporter → IO Bool
  , scriptPollEvents ∷ Reporter → IO ()
    -- ^ Runs inside a poll, before the events queued for it are delivered.
  , scriptWaitEvents ∷ Double → Reporter → IO ()
    -- ^ Runs inside a finite wait, given its bound, before the events queued
    -- for it are delivered. It may block, as a native wait does.
  , scriptPostEmptyEvent ∷ Reporter → IO ()
    -- ^ Runs inside a wake's empty-event post, on the thread that made it, with
    -- that call's wake mark current.
  , scriptMonitorTopology ∷ MonitorTopology
    -- ^ The monitors enumerated until a driver changes them.
  , scriptMonitorQuery ∷ Int → MonitorQuery → Reporter → IO ()
    -- ^ Runs inside each query targeting a monitor, before it answers.
  , scriptMonitorEnumeration ∷ Reporter → IO ()
    -- ^ Runs inside each enumeration, before it answers.
  , scriptWindowControl ∷ NativeCall → Reporter → IO ()
    -- ^ Runs inside each ordinary control call, given the call as recorded.
  , scriptWindowCapabilities ∷ Backend → WindowCapabilities
    -- ^ What windows cannot do or report on the session's backend.
  , scriptWindowMonitor ∷ Reporter → IO ()
    -- ^ Runs inside each query of a window's monitor, before it answers.
  , scriptTrackWindows ∷ Bool
    -- ^ Whether window size and position queries answer the geometry the seam
    -- tracks instead of the script.
  }

-- | A Linux platform on which every step succeeds silently: X11 is what an
-- unrequested session selects, Wayland is admitted only when a request names
-- it, and the prefix is built with both.
defaultScript ∷ SeamScript
defaultScript =
  SeamScript
    { scriptHostBackend = Just X11
    , scriptAdmittedBackends = [X11, Wayland]
    , scriptPlatformSupported = const True
    , scriptInitialize = \_ → pure True
    , scriptReportedPlatform = id
    , scriptTerminate = \_ → pure ()
    , scriptDetachErrorCallback = \_ → pure ()
    , scriptCreateWindow = \_ → pure True
    , scriptDestroyWindow = \_ → pure ()
    , scriptAttachWindowCallbacks = \_ → pure ()
    , scriptDetachWindowCallbacks = \_ → pure ()
    , scriptWindowSize = \_ → pure (800, 600)
    , scriptFramebufferSize = \_ → pure (1600, 1200)
    , scriptContentScale = \_ → pure (2, 2)
    , scriptWindowPosition = \_ → pure (40, 30)
    , scriptWindowAttribute = \_ _ → pure False
    , scriptPollEvents = \_ → pure ()
    , scriptWaitEvents = \_ _ → pure ()
    , scriptPostEmptyEvent = \_ → pure ()
    , scriptMonitorTopology = noMonitors
    , scriptMonitorQuery = \_ _ _ → pure ()
    , scriptMonitorEnumeration = \_ → pure ()
    , scriptWindowControl = \_ _ → pure ()
    , scriptWindowCapabilities = backendWindowCapabilities
    , scriptWindowMonitor = \_ → pure ()
    , scriptTrackWindows = False
    }

-- | The code the scripted library reports for a property it cannot provide.
featureUnavailableCode ∷ Int
featureUnavailableCode = 0x0001000C

-- | A scripted native library and what it has observed.
data Seam = Seam
  { seamScript ∷ SeamScript
  , seamGuard ∷ Guard
  , seamLog ∷ IORef [NativeCall]
    -- ^ Newest first.
  , seamMainThreads ∷ IORef [ThreadId]
  , seamIdentityFails ∷ IORef Bool
  , seamCallbacks ∷ IORef [(Int, ErrorCallback)]
    -- ^ Allocated and not yet freed callback storage, by key.
  , seamAttached ∷ IORef (Maybe Int)
  , seamNextKey ∷ IORef Int
  , seamHinted ∷ IORef (Maybe Backend)
  , seamNextWindow ∷ IORef Int
  , seamWindowCallbacks ∷ IORef [(Int, WindowCallbacks)]
    -- ^ Allocated and not yet freed window callback storage, by key.
  , seamAttachedWindows ∷ IORef [(Int, Int)]
    -- ^ Window key to the callback storage key attached to it.
  , seamQueuedEvents ∷ IORef [(Int, [WindowEvent])]
    -- ^ Events for the next poll or wait to deliver, by window key, oldest first.
  , seamQueuedControlEvents ∷ IORef [(Int, [WindowEvent])]
    -- ^ Events the next owner-thread control of that window delivers from
    -- inside the setter, as GLFW can invoke callbacks during a setter.
  , seamTopology ∷ IORef MonitorTopology
  , seamMonitorCallbacks ∷ IORef [(Int, MonitorCallback)]
    -- ^ Allocated and not yet freed monitor callback storage, by key.
  , seamAttachedMonitor ∷ IORef (Maybe Int)
  , seamQueuedMonitorEvents ∷ IORef [SeamMonitorEvent]
    -- ^ Monitor events for the next poll or wait to deliver, oldest first.
  , seamTracked ∷ IORef [(Int, Tracked)]
    -- ^ What the seam keeps of each live window, by window key.
  , seamReported ∷ IORef Int
    -- ^ How many errors scripted steps have reported.
  , seamReplacedModes ∷ IORef [(Int, Maybe NativeVideoMode)]
    -- ^ The current mode each monitor had before a fullscreen window changed it,
    -- by scripted address.
  , seamWakeMarks ∷ IORef [(ThreadId, WakeMark)]
    -- ^ The wake mark current on each thread inside a post.
  , seamWakeMarkFails ∷ IORef Bool
  , seamThreadErrors ∷ IORef [(ThreadId, Int)]
    -- ^ The last code a scripted step reported on each thread.
  }

-- | A window's tracked decoration, monitor address, size, and position.
data Tracked = Tracked
  { trackedDecorated ∷ Bool
  , trackedMonitor ∷ Int
  , trackedSize ∷ (Int, Int)
  , trackedPosition ∷ (Int, Int)
  }

-- | What a scripted step reports errors through.
newtype Reporter = Reporter Seam

-- | A fresh seam with a vacant guard and no designated main thread.
newSeam ∷ SeamScript → IO Seam
newSeam script =
  Seam script
    <$> newGuard
    <*> newIORef []
    <*> newIORef []
    <*> newIORef False
    <*> newIORef []
    <*> newIORef Nothing
    <*> newIORef 1
    <*> newIORef Nothing
    <*> newIORef 1
    <*> newIORef []
    <*> newIORef []
    <*> newIORef []
    <*> newIORef []
    <*> newIORef (scriptMonitorTopology script)
    <*> newIORef []
    <*> newIORef Nothing
    <*> newIORef []
    <*> newIORef []
    <*> newIORef 0
    <*> newIORef []
    <*> newIORef []
    <*> newIORef False
    <*> newIORef []

-- | Enter a session over this seam's native table.
seamSession ∷ Seam → SessionConfig → Scoped Session
seamSession seam = allocComposite . sessionAssembly (seamNative seam)

-- | Every native call so far, oldest first.
seamCalls ∷ Seam → IO [NativeCall]
seamCalls seam = reverse <$> readIORef (seamLog seam)

-- | How many allocated callback storages have not been freed.
seamLiveCallbacks ∷ Seam → IO Int
seamLiveCallbacks seam = length <$> readIORef (seamCallbacks seam)

-- | How many allocated window callback storages have not been freed.
seamLiveWindowCallbacks ∷ Seam → IO Int
seamLiveWindowCallbacks seam = length <$> readIORef (seamWindowCallbacks seam)

-- | How many allocated monitor callback storages have not been freed.
seamLiveMonitorCallbacks ∷ Seam → IO Int
seamLiveMonitorCallbacks seam = length <$> readIORef (seamMonitorCallbacks seam)

-- | Replace the monitors the scripted platform enumerates. Nothing is
-- delivered to the monitor callback.
seamSetMonitorTopology ∷ Seam → MonitorTopology → IO ()
seamSetMonitorTopology seam = atomicWriteIORef (seamTopology seam)

-- | Invoke the attached monitor callback with each event, in order, on the
-- calling thread. With no callback attached the events are dropped, as GLFW
-- drops them.
seamDeliverMonitorEvents ∷ Seam → [SeamMonitorEvent] → IO ()
seamDeliverMonitorEvents seam events = do
  attached ← readIORef (seamAttachedMonitor seam)
  stored ← readIORef (seamMonitorCallbacks seam)
  mapM_ (deliver (attached >>= (`lookup` stored))) events
  where
    -- As GLFW does, a disconnection first takes every window on the monitor off
    -- it, at the desktop origin, and then invokes the callback.
    deliver callback = \case
      MonitorAttached key → mapM_ (\invoke → invoke (monitorPointer key) glfwConnectedCode) callback
      MonitorDetached key → do
        atomicModifyIORef' (seamReplacedModes seam) (\replaced → (filter ((/= key) . fst) replaced, ()))
        atomicModifyIORef' (seamTracked seam) $ \tracked →
          ([(window, if trackedMonitor state == key then state {trackedMonitor = 0, trackedPosition = (0, 0)} else state) | (window, state) ← tracked], ())
        mapM_ (\invoke → invoke (monitorPointer key) glfwDisconnectedCode) callback
      other → mapM_ (\invoke → deliverOther invoke other) callback
    deliverOther callback = \case
      MonitorAttached key → callback (monitorPointer key) glfwConnectedCode
      MonitorDetached key → callback (monitorPointer key) glfwDisconnectedCode
      MonitorEventCode key code → callback (monitorPointer key) code
      MonitorEventRaises key failure → callback (monitorPointer key) (throw failure)

-- | Queue monitor events for the next poll or finite wait over this seam's
-- native table, which delivers them from inside that call.
seamQueueMonitorEvents ∷ Seam → [SeamMonitorEvent] → IO ()
seamQueueMonitorEvents seam events =
  atomicModifyIORef' (seamQueuedMonitorEvents seam) (\queued → (queued <> events, ()))

-- | GLFW's connection event codes.
glfwConnectedCode, glfwDisconnectedCode ∷ CInt
glfwConnectedCode = 0x00040001
glfwDisconnectedCode = 0x00040002

monitorPointer ∷ Int → Ptr NativeMonitor
monitorPointer = intPtrToPtr . fromIntegral

monitorKey ∷ Ptr NativeMonitor → Int
monitorKey = fromIntegral . ptrToIntPtr

-- | A seam driver was handed a window its seam did not create.
data ForeignSeamWindow = ForeignSeamWindow
  deriving (Eq, Show)

instance Exception ForeignSeamWindow

-- | Refuse a window whose session was not entered over this seam's native table.
requireSeamWindow ∷ Seam → Window → IO ()
requireSeamWindow seam window =
  unless (nativeGuard (sessionNative (windowSession window)) == seamGuard seam) $
    throwIO ForeignSeamWindow

-- | Deliver events to a window's attached callbacks from inside one owner
-- boundary step, then let the model reconcile them. An ended window answers
-- without a native step; events for a window with no callbacks attached are
-- dropped, as GLFW drops them.
seamDrive ∷ Seam → Window → DriveOrigin → [WindowEvent] → IO (WindowResult ())
seamDrive = seamDriveWith (pure ())

-- | 'seamDrive' with an interruption at the reconciliation boundary: once
-- before the commit, and again inside the masked publication step.
seamDriveWith ∷ IO () → Seam → Window → DriveOrigin → [WindowEvent] → IO (WindowResult ())
seamDriveWith interruption seam window origin = driveWith interruption seam window (originName origin)
  where
    originName DuringSetter = "seam setter"
    originName DuringPoll = "seam poll"

-- | 'seamDrive' from inside a poll, with a cancellation delivered to the owner
-- at the reconciliation's preparation point: after the captures were folded and
-- the next observation prepared, before anything is committed.
seamDriveCancelledBeforeCommit ∷ Seam → Window → [WindowEvent] → IO (WindowResult ())
seamDriveCancelledBeforeCommit seam window = driveWith (throwIO ThreadKilled) seam window "seam poll"

driveWith ∷ IO () → Seam → Window → Text → [WindowEvent] → IO (WindowResult ())
driveWith interruption seam window originName events = do
  requireSeamWindow seam window
  windowStepWith interruption window (operation originName) $ \handle →
    deliverTo seam (windowKey handle) events

-- | Queue events for a window's attached callbacks. The next poll or finite
-- wait over this seam's native table delivers them from inside that call, as
-- GLFW delivers events from inside a poll; nothing is delivered before it.
seamQueueEvents ∷ Seam → Window → [WindowEvent] → IO ()
seamQueueEvents seam window events = do
  requireSeamWindow seam window
  let key = windowKey (windowNativeHandle window)
  atomicModifyIORef' (seamQueuedEvents seam) (\queued → (queued <> [(key, events)], ()))

-- | Queue events for a window's attached callbacks. The next ordinary control
-- of that window over this seam's native table delivers them from inside the
-- setter, as GLFW can invoke callbacks during a setter.
seamQueueControlEvents ∷ Seam → Window → [WindowEvent] → IO ()
seamQueueControlEvents seam window events = do
  requireSeamWindow seam window
  let key = windowKey (windowNativeHandle window)
  atomicModifyIORef' (seamQueuedControlEvents seam) (\queued → (queued <> [(key, events)], ()))

deliverQueuedControl ∷ Seam → Int → IO ()
deliverQueuedControl seam key = do
  events ← atomicModifyIORef' (seamQueuedControlEvents seam) $ \queued →
    ( [(k, es) | (k, es) ← queued, k /= key]
    , concat [es | (k, es) ← queued, k == key]
    )
  deliverTo seam key events

controlWindowKey ∷ NativeCall → Maybe Int
controlWindowKey = \case
  SetWindowTitle key _ → Just key
  SetWindowSize key _ _ → Just key
  SetWindowPosition key _ _ → Just key
  SetWindowSizeLimits key _ _ _ _ → Just key
  SetWindowAspectRatio key _ → Just key
  ShowWindow key → Just key
  HideWindow key → Just key
  FocusWindow key → Just key
  RequestWindowAttention key → Just key
  IconifyWindow key → Just key
  MaximizeWindow key → Just key
  RestoreWindow key → Just key
  SetWindowMonitor key _ _ _ _ _ _ → Just key
  SetWindowDecorated key _ → Just key
  ClearWindowSizeLimits key → Just key
  _ → Nothing

-- | Deliver events to the callbacks attached to a window key. Events for a
-- window with no callbacks attached are dropped, as GLFW drops them.
deliverTo ∷ Seam → Int → [WindowEvent] → IO ()
deliverTo seam key events = do
  attached ← readIORef (seamAttachedWindows seam)
  stored ← readIORef (seamWindowCallbacks seam)
  case lookup key attached >>= (`lookup` stored) of
    Nothing → pure ()
    Just callbacks → mapM_ (\event → track event >> deliver callbacks event) events
  where
    track = \case
      ResizedTo width height | scriptTrackWindows (seamScript seam) → trackWindow seam key (\state → state {trackedSize = (width, height)})
      MovedTo x y | scriptTrackWindows (seamScript seam) → trackWindow seam key (\state → state {trackedPosition = (x, y)})
      _ → pure ()
    deliver callbacks event = case event of
      ResizedTo width height → onWindowSize callbacks (fromIntegral width) (fromIntegral height)
      FramebufferResizedTo width height → onFramebufferSize callbacks (fromIntegral width) (fromIntegral height)
      ContentScaledTo x y → onContentScale callbacks (realToFrac x) (realToFrac y)
      MovedTo x y → onWindowPosition callbacks (fromIntegral x) (fromIntegral y)
      FocusChanged flag → onWindowFocus callbacks (flagOf flag)
      IconifyChanged flag → onWindowIconify callbacks (flagOf flag)
      MaximizeChanged flag → onWindowMaximize callbacks (flagOf flag)
      RefreshRequested → onWindowRefresh callbacks
      CloseRequested → onWindowClose callbacks
      KeyEventAt code scancode action mods →
        onKey callbacks (fromIntegral code) (fromIntegral scancode) (fromIntegral action) (fromIntegral mods)
      CharEventAt codepoint → onChar callbacks (fromIntegral codepoint)
      ButtonEventAt button action mods →
        onMouseButton callbacks (fromIntegral button) (fromIntegral action) (fromIntegral mods)
      CursorMovedTo x y → onCursorPos callbacks (realToFrac x) (realToFrac y)
      CursorEnterChanged entered → onCursorEnter callbacks (flagOf entered)
      ScrollEventAt x y → onScroll callbacks (realToFrac x) (realToFrac y)
      CallbackRaises failure → onWindowSize callbacks (throw failure) 1
    flagOf flag = if flag then 1 else 0

-- | Reject a close request through the model's private transition, on a window
-- this seam created.
seamRejectCloseRequest ∷ Seam → Window → CloseRequest → IO (WindowResult Bool)
seamRejectCloseRequest seam window request = do
  requireSeamWindow seam window
  rejectCloseRequest window request

-- | Set or clear the window's private mode transition marker, on a window this
-- seam created.
seamSetModeTransition ∷ Seam → Window → Bool → IO ()
seamSetModeTransition seam window transition = do
  requireSeamWindow seam window
  setModeTransition window transition

-- | Execute the oldest queued command against the given windows, on a host this
-- seam's session created.
seamExecuteNext ∷ Seam → WindowCommandHost → [Window] → IO ExecutionStep
seamExecuteNext seam host = seamExecuteNextInterrupted seam host (pure ())

-- | 'seamExecuteNext', running @afterClaim@ immediately after the claim, inside
-- the protection that settles an interrupted command.
seamExecuteNextInterrupted ∷ Seam → WindowCommandHost → IO () → [Window] → IO ExecutionStep
seamExecuteNextInterrupted seam host afterClaim windows = do
  requireSeamHost seam host
  executeNextWith afterClaim host (executeCommand windows)

-- | Claim the oldest queued command and settle it with a scripted execution in
-- place of the real one, under the same protection.
seamExecuteNextScripted
  ∷ Seam
  → WindowCommandHost
  → (CommandOrigin → WindowCommand → IO (Either CommandRejection CommandResult))
  → IO ExecutionStep
seamExecuteNextScripted seam host work = do
  requireSeamHost seam host
  executeNextWith (pure ()) host (\origin command → Completed <$> work origin command)

-- | Refuse a host whose session was not entered over this seam's native table.
requireSeamHost ∷ Seam → WindowCommandHost → IO ()
requireSeamHost seam host =
  unless (nativeGuard (sessionNative (commandHostSession host)) == seamGuard seam) $
    throwIO ForeignSeamWindow

-- | Treat the calling Haskell thread as the process main thread.
designateProcessMainThread ∷ Seam → IO ()
designateProcessMainThread seam = do
  self ← myThreadId
  atomicModifyIORef' (seamMainThreads seam) (\threads → (self : threads, ()))

-- | Run an action in a bound thread designated as the process main thread.
asProcessMainThread ∷ Seam → IO a → IO a
asProcessMainThread seam action = runInBoundThread (designateProcessMainThread seam >> action)

-- | Invoke the attached error callback on the calling thread, as GLFW does
-- from inside a failing call. With no callback attached the report is dropped,
-- as GLFW drops it.
reportError ∷ Reporter → Int → ByteString → IO ()
reportError (Reporter seam) code description = do
  atomicModifyIORef' (seamReported seam) (\count → (count + 1, ()))
  self ← myThreadId
  atomicModifyIORef' (seamThreadErrors seam) (\codes → ((self, code) : filter ((/= self) . fst) codes, ()))
  attached ← readIORef (seamAttached seam)
  callbacks ← readIORef (seamCallbacks seam)
  case attached >>= (`lookup` callbacks) of
    Nothing → pure ()
    Just callback →
      ByteString.useAsCString description (callback (fromIntegral code))

-- | Invoke the attached error callback from another, undesignated thread and
-- wait for it to return. Anything that escaped the callback is rethrown here,
-- so an example can observe that nothing did.
reportErrorFromOtherThread ∷ Reporter → Int → ByteString → IO ()
reportErrorFromOtherThread reporter code description = do
  finished ← newEmptyMVar
  _ ← forkIO (try (reportError reporter code description) >>= putMVar finished)
  outcome ← takeMVar finished
  either (throwIO ∷ SomeException → IO ()) pure outcome

-- | Invoke the attached error callback on the calling thread while the
-- thread-identity query fails.
reportErrorWithFailingIdentity ∷ Reporter → Int → ByteString → IO ()
reportErrorWithFailingIdentity reporter@(Reporter seam) code description = do
  atomicWriteIORef (seamIdentityFails seam) True
  reportError reporter code description `finally` atomicWriteIORef (seamIdentityFails seam) False

-- | Invoke the attached error callback on the calling thread while the wake
-- mark query fails.
reportErrorWithFailingWakeMark ∷ Reporter → Int → ByteString → IO ()
reportErrorWithFailingWakeMark reporter@(Reporter seam) code description = do
  atomicWriteIORef (seamWakeMarkFails seam) True
  reportError reporter code description `finally` atomicWriteIORef (seamWakeMarkFails seam) False

-- | Change what the seam tracks of a window.
trackWindow ∷ Seam → Int → (Tracked → Tracked) → IO ()
trackWindow seam key change =
  atomicModifyIORef' (seamTracked seam) (\tracked → ([(window, if window == key then change state else state) | (window, state) ← tracked], ()))

-- | The scripted key a seam window handle stands for.
windowKey ∷ Ptr NativeWindow → Int
windowKey = fromIntegral . ptrToIntPtr

seamNative ∷ Seam → Native
seamNative seam =
  Native
    { nativeHostBackend = scriptHostBackend script
    , nativeAdmittedBackends = scriptAdmittedBackends script
    , nativeGuard = seamGuard seam
    , nativeIsProcessMainThread = identity
    , nativePlatformSupported = \backend → do
        record (QueryPlatformSupported backend)
        pure (scriptPlatformSupported script backend)
    , nativeNewErrorCallback = \callback → do
        record CreateErrorCallback
        key ← atomicModifyIORef' (seamNextKey seam) (\next → (next + 1, next))
        atomicModifyIORef' (seamCallbacks seam) (\stored → ((key, callback) : stored, ()))
        pure (CallbackStorage (castPtrToFunPtr (intPtrToPtr (fromIntegral key))))
    , nativeAttachErrorCallback = \storage → do
        record AttachErrorCallback
        atomicWriteIORef (seamAttached seam) (Just (keyOf storage))
    , nativeDetachErrorCallback = do
        record DetachErrorCallback
        scriptDetachErrorCallback script reporter
        atomicWriteIORef (seamAttached seam) Nothing
    , nativeFreeErrorCallback = \storage → do
        record FreeErrorCallback
        atomicModifyIORef' (seamCallbacks seam) $ \stored →
          (filter ((/= keyOf storage) . fst) stored, ())
    , nativeSetInitHints = \backend → do
        record (SetInitHints backend)
        atomicWriteIORef (seamHinted seam) (Just backend)
    , nativeInitialize = do
        record Initialize
        scriptInitialize script reporter
    , nativeCurrentBackend = do
        record QueryPlatform
        scriptReportedPlatform script <$> readIORef (seamHinted seam)
    , nativeTerminate = do
        record Terminate
        scriptTerminate script reporter
    , nativeResetWindowHints = record ResetWindowHints
    , nativeSetWindowHint = record . SetWindowHint
    , nativeCreateWindow = \width height title → do
        record (CreateWindow width height title)
        live ← scriptCreateWindow script reporter
        if live
          then do
            handle ← atomicModifyIORef' (seamNextWindow seam) (\next → (next + 1, next))
            atomicModifyIORef' (seamTracked seam) $ \tracked →
              ((handle, Tracked True 0 (fromIntegral width, fromIntegral height) (40, 30)) : tracked, ())
            pure (intPtrToPtr (fromIntegral handle))
          else pure nullPtr
    , nativeDestroyWindow = \handle → do
        record (DestroyWindow (windowKey handle))
        scriptDestroyWindow script reporter
        leaving ← maybe 0 trackedMonitor . lookup (windowKey handle) <$> readIORef (seamTracked seam)
        restoreMode leaving
        atomicModifyIORef' (seamTracked seam) (\tracked → (filter ((/= windowKey handle) . fst) tracked, ()))
    , nativeNewWindowCallbacks = \callbacks → do
        record CreateWindowCallbacks
        key ← atomicModifyIORef' (seamNextKey seam) (\next → (next + 1, next))
        atomicModifyIORef' (seamWindowCallbacks seam) (\stored → ((key, callbacks) : stored, ()))
        pure (WindowCallbackStorage [castPtrToFunPtr (intPtrToPtr (fromIntegral key))])
    , nativeAttachWindowCallbacks = \handle storage → do
        record (AttachWindowCallbacks (windowKey handle))
        scriptAttachWindowCallbacks script reporter
        atomicModifyIORef' (seamAttachedWindows seam) $ \attached →
          ((windowKey handle, storageKey storage) : attached, ())
    , nativeDetachWindowCallbacks = \handle → do
        record (DetachWindowCallbacks (windowKey handle))
        scriptDetachWindowCallbacks script reporter
        atomicModifyIORef' (seamAttachedWindows seam) $ \attached →
          (filter ((/= windowKey handle) . fst) attached, ())
    , nativeFreeWindowCallbacks = \storage → do
        record FreeWindowCallbacks
        atomicModifyIORef' (seamWindowCallbacks seam) $ \stored →
          (filter ((/= storageKey storage) . fst) stored, ())
    , nativeWindowSize = \handle → do
        record QueryWindowSize
        scripted ← scriptWindowSize script reporter
        tracking handle trackedSize scripted
    , nativeFramebufferSize = \_ → record QueryFramebufferSize >> scriptFramebufferSize script reporter
    , nativeContentScale = \_ → record QueryContentScale >> scriptContentScale script reporter
    , nativeWindowPosition = \handle → do
        record QueryWindowPosition
        scripted ← scriptWindowPosition script reporter
        tracking handle trackedPosition scripted
    , nativeWindowAttribute = \handle attribute → do
        record (QueryWindowAttribute attribute)
        scripted ← scriptWindowAttribute script attribute reporter
        case attribute of
          DecoratedAttribute → maybe True trackedDecorated . lookup (windowKey handle) <$> readIORef (seamTracked seam)
          _ → pure scripted
    , nativePollEvents = do
        record PollEvents
        scriptPollEvents script reporter
        deliverQueued
    , nativeWaitEventsTimeout = \seconds → do
        record (WaitEvents seconds)
        scriptWaitEvents script seconds reporter
        deliverQueued
    , nativePostEmptyEvent = \mark → do
        record PostEmptyEvent
        self ← myThreadId
        let others ∷ [(ThreadId, a)] → [(ThreadId, a)]
            others = filter ((/= self) . fst)
        atomicModifyIORef' (seamThreadErrors seam) (\codes → (others codes, ()))
        atomicModifyIORef' (seamWakeMarks seam) (\marks → ((self, mark) : others marks, ()))
        scriptPostEmptyEvent script reporter
          `finally` atomicModifyIORef' (seamWakeMarks seam) (\marks → (others marks, ()))
        atomicModifyIORef' (seamThreadErrors seam) (\codes → (others codes, maybe 0 id (lookup self codes)))
    , nativeCurrentWakeMark = do
        failing ← readIORef (seamWakeMarkFails seam)
        when failing (throwIO (userError "the scripted wake mark query failed"))
        self ← myThreadId
        maybe noWakeMark id . lookup self <$> readIORef (seamWakeMarks seam)
    , nativeSetWindowTitle = \handle title → control (SetWindowTitle (windowKey handle) title)
    , nativeSetWindowSize = \handle width height → control (SetWindowSize (windowKey handle) width height)
    , nativeSetWindowPosition = \handle x y → control (SetWindowPosition (windowKey handle) x y)
    , nativeSetWindowSizeLimits = \handle minimumWidth minimumHeight maximumWidth maximumHeight →
        control (SetWindowSizeLimits (windowKey handle) minimumWidth minimumHeight maximumWidth maximumHeight)
    , nativeSetWindowAspectRatio = \handle ratio → control (SetWindowAspectRatio (windowKey handle) ratio)
    , nativeShowWindow = control . ShowWindow . windowKey
    , nativeHideWindow = control . HideWindow . windowKey
    , nativeFocusWindow = control . FocusWindow . windowKey
    , nativeRequestWindowAttention = control . RequestWindowAttention . windowKey
    , nativeIconifyWindow = control . IconifyWindow . windowKey
    , nativeMaximizeWindow = control . MaximizeWindow . windowKey
    , nativeRestoreWindow = control . RestoreWindow . windowKey
    , nativeWindowMonitor = \handle → do
        record QueryWindowMonitor
        scriptWindowMonitor script reporter
        monitorPointer . maybe 0 trackedMonitor . lookup (windowKey handle) <$> readIORef (seamTracked seam)
    , nativeSetWindowMonitor = \handle monitor x y width height refresh →
        control (SetWindowMonitor (windowKey handle) (monitorKey monitor) x y width height refresh)
    , nativeSetWindowDecorated = \handle decorated → control (SetWindowDecorated (windowKey handle) decorated)
    , nativeClearWindowSizeLimits = control . ClearWindowSizeLimits . windowKey
    , nativeWindowCapabilities = scriptWindowCapabilities script
    , nativePlatformError = 0x00010008
    , nativeFeatureUnavailable = featureUnavailableCode
    , nativeMonitor =
        MonitorNative
          { nativeMonitors = do
              record QueryMonitors
              scriptMonitorEnumeration script reporter
              fmap (map (monitorPointer . fst)) . topologyMonitors <$> readIORef (seamTopology seam)
          , nativePrimaryMonitor = do
              record QueryPrimaryMonitor
              monitorPointer . topologyPrimary <$> readIORef (seamTopology seam)
          , nativeMonitorName = monitorQuery NameQuery (pure . scriptedName)
          , nativeMonitorPosition = monitorQuery PositionQuery (pure . scriptedPosition)
          , nativeMonitorWorkArea = monitorQuery WorkAreaQuery (pure . scriptedWorkArea)
          , nativeMonitorPhysicalSize = monitorQuery PhysicalSizeQuery (pure . scriptedPhysicalSize)
          , nativeMonitorContentScale = monitorQuery ContentScaleQuery (pure . scriptedContentScale)
          , nativeMonitorCurrentMode = monitorQuery CurrentModeQuery (pure . scriptedCurrentMode)
          , nativeMonitorVideoModes = monitorQuery VideoModesQuery (pure . scriptedVideoModes)
          , nativeNewMonitorCallback = \callback → do
              record CreateMonitorCallback
              key ← atomicModifyIORef' (seamNextKey seam) (\next → (next + 1, next))
              atomicModifyIORef' (seamMonitorCallbacks seam) (\stored → ((key, callback) : stored, ()))
              pure (MonitorCallbackStorage (castPtrToFunPtr (intPtrToPtr (fromIntegral key))))
          , nativeAttachMonitorCallback = \(MonitorCallbackStorage pointer) → do
              record AttachMonitorCallback
              atomicWriteIORef (seamAttachedMonitor seam) (Just (fromIntegral (ptrToIntPtr (castFunPtrToPtr pointer))))
          , nativeDetachMonitorCallback = do
              record DetachMonitorCallback
              atomicWriteIORef (seamAttachedMonitor seam) Nothing
          , nativeFreeMonitorCallback = \(MonitorCallbackStorage pointer) → do
              record FreeMonitorCallback
              let key = fromIntegral (ptrToIntPtr (castFunPtrToPtr pointer))
              atomicModifyIORef' (seamMonitorCallbacks seam) (\stored → (filter ((/= key) . fst) stored, ()))
          , nativeMonitorConnected = glfwConnectedCode
          , nativeMonitorDisconnected = glfwDisconnectedCode
          }
    }
  where
    control call = do
      record call
      before ← readIORef (seamReported seam)
      scriptWindowControl script call reporter
      forM_ (controlWindowKey call) (deliverQueuedControl seam)
      after ← readIORef (seamReported seam)
      when (before == after) (effect call)
    -- What a control or mode step that reported no error changes.
    effect = \case
      SetWindowSize key width height
        | scriptTrackWindows script → trackWindow seam key (\state → state {trackedSize = (fromIntegral width, fromIntegral height)})
      SetWindowPosition key x y
        | scriptTrackWindows script → trackWindow seam key (\state → state {trackedPosition = (fromIntegral x, fromIntegral y)})
      SetWindowMonitor key monitor x y width height refresh → do
        previous ← maybe 0 trackedMonitor . lookup key <$> readIORef (seamTracked seam)
        when (previous /= 0 && previous /= monitor) (restoreMode previous)
        when (monitor /= 0) (replaceMode monitor (fromIntegral width) (fromIntegral height) (fromIntegral <$> refresh))
        topology ← readIORef (seamTopology seam)
        let position
              | monitor == 0 = (fromIntegral x, fromIntegral y)
              | otherwise = maybe (0, 0) (\(mx, my) → (fromIntegral mx, fromIntegral my)) (scriptedPosition <$> (lookup monitor =<< topologyMonitors topology))
        trackWindow seam key (\state → state {trackedMonitor = monitor, trackedPosition = position, trackedSize = (fromIntegral width, fromIntegral height)})
      SetWindowDecorated key decorated → trackWindow seam key (\state → state {trackedDecorated = decorated})
      _ → pure ()
    -- A fullscreen window's video mode becomes its monitor's current one; the
    -- mode it replaced is kept, once, to restore.
    replaceMode ∷ Int → CInt → CInt → Maybe CInt → IO ()
    replaceMode monitor width height refresh = do
      topology ← readIORef (seamTopology seam)
      case lookup monitor =<< topologyMonitors topology of
        Nothing → pure ()
        Just scripted → do
          atomicModifyIORef' (seamReplacedModes seam) $ \replaced →
            (if any ((== monitor) . fst) replaced then replaced else (monitor, scriptedCurrentMode scripted) : replaced, ())
          let rate = maybe (maybe 60 nativeModeRefreshRate (scriptedCurrentMode scripted)) id refresh
          setCurrentMode monitor (Just (NativeVideoMode width height 8 8 8 rate))
    restoreMode ∷ Int → IO ()
    restoreMode monitor = do
      saved ← atomicModifyIORef' (seamReplacedModes seam) $ \replaced →
        (filter ((/= monitor) . fst) replaced, lookup monitor replaced)
      mapM_ (setCurrentMode monitor) saved
    setCurrentMode monitor mode =
      atomicModifyIORef' (seamTopology seam) $ \topology →
        ( topology
            { topologyMonitors =
                map (\(address, entry) → if address == monitor then (address, entry {scriptedCurrentMode = mode}) else (address, entry))
                  <$> topologyMonitors topology
            }
        , ()
        )
    tracking ∷ Ptr NativeWindow → (Tracked → (Int, Int)) → (Int, Int) → IO (Int, Int)
    tracking handle field scripted
      | scriptTrackWindows script = maybe scripted field . lookup (windowKey handle) <$> readIORef (seamTracked seam)
      | otherwise = pure scripted
    deliverQueued = do
      atomicModifyIORef' (seamQueuedEvents seam) (\queued → ([], queued))
        >>= mapM_ (uncurry (deliverTo seam))
      atomicModifyIORef' (seamQueuedMonitorEvents seam) (\queued → ([], queued))
        >>= seamDeliverMonitorEvents seam
    -- A query for an address the topology no longer lists answers what the
    -- last monitor there reported would be unknowable, so it raises instead:
    -- the model must never query a monitor it did not just enumerate.
    monitorQuery ∷ MonitorQuery → (ScriptedMonitor → IO a) → Ptr NativeMonitor → IO a
    monitorQuery query answer pointer = do
      let key = monitorKey pointer
      record (QueryMonitor key query)
      scriptMonitorQuery script key query reporter
      listed ← topologyMonitors <$> readIORef (seamTopology seam)
      case lookup key =<< listed of
        Just monitor → answer monitor
        Nothing → throwIO (userError ("the scripted monitor at address " <> show key <> " is not connected"))
    script = seamScript seam
    reporter = Reporter seam
    record call = atomicModifyIORef' (seamLog seam) (\calls → (call : calls, ()))
    keyOf (CallbackStorage pointer) = fromIntegral (ptrToIntPtr (castFunPtrToPtr pointer))
    storageKey (WindowCallbackStorage pointers) = case pointers of
      [pointer] → fromIntegral (ptrToIntPtr (castFunPtrToPtr pointer))
      _ → 0
    identity = do
      failing ← readIORef (seamIdentityFails seam)
      if failing
        then throwIO (userError "the scripted thread identity query failed")
        else do
          self ← myThreadId
          elem self <$> readIORef (seamMainThreads seam)
