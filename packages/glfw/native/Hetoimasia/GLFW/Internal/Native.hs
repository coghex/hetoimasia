{-# LANGUAGE CApiFFI #-}

-- | The private binding to upstream GLFW 3.4, and the production native table.
--
-- Only the operations the session, window, and monitor models use are bound. Every function and
-- constant is imported through @hetoimasia_glfw.h@, which includes the
-- installed @GLFW/glfw3.h@, so the C compiler checks each declaration and every
-- constant's value comes from the header rather than from a copied number. The
-- production finite event wait is made through the shim's
-- @hetoimasia_glfw_wait_events_timeout@, which records the waiting thread and a
-- per-wait sequence number for the native examples, then calls
-- @glfwWaitEventsTimeout@. The monitor enumeration, name, and video mode getters
-- are reached through shim accessors that only restate GLFW's @const@ return
-- types as the generated wrappers declare them, and video modes are copied
-- field by field through @hetoimasia_glfw_video_mode_at@, so no structure
-- layout is assumed, and
-- every array and string GLFW returns is copied before the operation returns.
-- The window title getter, used only by the native examples, is reached the
-- same way through @hetoimasia_glfw_window_title@.
-- The exceptions to CAPI imports are @glfwSetErrorCallback@, @glfwSetMonitorCallback@, and the window callback setters,
-- imported with @ccall@: their argument is a function pointer whose C type the
-- CAPI wrapper cannot spell, and it is passed and returned as a plain pointer.
--
-- Every GLFW function is a @safe@ import. Any of them may report an error
-- through the callback, which re-enters Haskell and is only permitted from a
-- safe call, and a safe call lets other Haskell threads run while it is in C.
-- The thread-identity shim calls nothing and is @unsafe@.
--
-- The process-wide 'Guard' lives here, beside the library whose state it
-- guards. It holds only occupancy and poison.
module Hetoimasia.GLFW.Internal.Native
  ( productionNative

    -- * Error codes
  , glfwPlatformUnavailable

    -- * Native example drivers
  , installedMonitorCallbackForCheck
  , setWindowSizeForCheck
  , pollEventsForCheck
  , waitEventsForCheck
  , requestCloseForCheck
  , noteProgressForCheck
  , takeWaitNotedForCheck
  , leakResizableHintForCheck
  , windowResizableForCheck
  , windowSizeForCheck
  , windowPositionForCheck
  , windowTitleForCheck
  , sizeLimitsForCheck
  , windowFullscreenForCheck
  , WindowStateForCheck (..)
  , windowStateForCheck
  ) where

import Control.Exception (onException)
import Control.Monad (void)
import qualified Data.ByteString as ByteString
import Data.Int (Int32)
import Data.Text (Text)
import Data.Text.Encoding (decodeUtf8Lenient, encodeUtf8)
import Foreign.C.String (CString)
import Foreign.C.Types (CDouble (CDouble), CFloat (CFloat), CInt (CInt))
import Foreign.Marshal.Alloc (alloca)
import Foreign.Marshal.Array (allocaArray, peekArray)
import Foreign.Ptr (FunPtr, Ptr, castFunPtr, freeHaskellFunPtr, nullFunPtr, nullPtr)
import Foreign.Storable (Storable, peek, peekElemOff)
import Hetoimasia.GLFW.Internal.Capture (ErrorCallback)
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
  , WindowAttribute (..)
  , WindowCallbackStorage (WindowCallbackStorage)
  , WindowCallbacks (..)
  , WindowHint (..)
  , backendWindowCapabilities
  , newGuard
  )
import System.IO.Unsafe (unsafePerformIO)
import System.Info (os)

-- | The operations a session performs, bound to GLFW.
productionNative ∷ Native
productionNative =
  Native
    { nativeHostBackend = hostBackend
    , nativeGuard = processGuard
    , nativeIsProcessMainThread = (/= 0) <$> c_isProcessMainThread
    , nativePlatformSupported = \backend →
        (== glfwTrue) <$> c_glfwPlatformSupported (platformCode backend)
    , nativeNewErrorCallback = fmap CallbackStorage . c_wrapErrorCallback
    , nativeAttachErrorCallback = \(CallbackStorage callback) →
        void (c_glfwSetErrorCallback callback)
    , nativeDetachErrorCallback = void (c_glfwSetErrorCallback nullFunPtr)
    , nativeFreeErrorCallback = \(CallbackStorage callback) → freeHaskellFunPtr callback
    , nativeSetInitHints = \backend → do
        c_glfwInitHint glfwPlatformHint (platformCode backend)
        c_glfwInitHint glfwCocoaChdirResources glfwFalse
    , nativeInitialize = (== glfwTrue) <$> c_glfwInit
    , nativeCurrentBackend = platformBackend <$> c_glfwGetPlatform
    , nativeTerminate = c_glfwTerminate
    , nativeResetWindowHints = c_glfwDefaultWindowHints
    , nativeSetWindowHint = setWindowHint
    , nativeCreateWindow = createWindow
    , nativeDestroyWindow = c_glfwDestroyWindow
    , nativeNewWindowCallbacks = newWindowCallbacks
    , nativeAttachWindowCallbacks = attachWindowCallbacks
    , nativeDetachWindowCallbacks = detachWindowCallbacks
    , nativeFreeWindowCallbacks = \(WindowCallbackStorage pointers) → mapM_ freeHaskellFunPtr pointers
    , nativeWindowSize = pairOf c_glfwGetWindowSize fromIntegral
    , nativeFramebufferSize = pairOf c_glfwGetFramebufferSize fromIntegral
    , nativeContentScale = pairOf c_glfwGetWindowContentScale realToFrac
    , nativeWindowPosition = pairOf c_glfwGetWindowPos fromIntegral
    , nativeWindowAttribute = \window attribute →
        (/= glfwFalse) <$> c_glfwGetWindowAttrib window (attributeCode attribute)
    , nativePollEvents = c_glfwPollEvents
    , nativeWaitEventsTimeout = c_waitEventsTimeout . CDouble
    , nativeSetWindowTitle = \window title →
        ByteString.useAsCString (encodeUtf8 title) (c_glfwSetWindowTitle window)
    , nativeSetWindowSize = \window width height → c_glfwSetWindowSize window (fromIntegral width) (fromIntegral height)
    , nativeSetWindowPosition = \window x y → c_glfwSetWindowPos window (fromIntegral x) (fromIntegral y)
    , nativeSetWindowSizeLimits = \window minimumWidth minimumHeight maximumWidth maximumHeight →
        c_glfwSetWindowSizeLimits
          window
          (fromIntegral minimumWidth)
          (fromIntegral minimumHeight)
          (fromIntegral maximumWidth)
          (fromIntegral maximumHeight)
    , nativeSetWindowAspectRatio = \window ratio → case ratio of
        Just (numerator, denominator) → c_glfwSetWindowAspectRatio window (fromIntegral numerator) (fromIntegral denominator)
        Nothing → c_glfwSetWindowAspectRatio window glfwDontCare glfwDontCare
    , nativeShowWindow = c_glfwShowWindow
    , nativeHideWindow = c_glfwHideWindow
    , nativeFocusWindow = c_glfwFocusWindow
    , nativeRequestWindowAttention = c_glfwRequestWindowAttention
    , nativeIconifyWindow = c_glfwIconifyWindow
    , nativeMaximizeWindow = c_glfwMaximizeWindow
    , nativeRestoreWindow = c_glfwRestoreWindow
    , nativeWindowMonitor = c_glfwGetWindowMonitor
    , nativeSetWindowMonitor = \window monitor x y width height refresh →
        c_glfwSetWindowMonitor
          window
          monitor
          (fromIntegral x)
          (fromIntegral y)
          (fromIntegral width)
          (fromIntegral height)
          (maybe glfwDontCare fromIntegral refresh)
    , nativeSetWindowDecorated = \window decorated → c_glfwSetWindowAttrib window glfwDecorated (boolean decorated)
    , nativeClearWindowSizeLimits = \window →
        c_glfwSetWindowSizeLimits window glfwDontCare glfwDontCare glfwDontCare glfwDontCare
    , nativeWindowCapabilities = backendWindowCapabilities
    , nativeFeatureUnavailable = fromIntegral glfwFeatureUnavailable
    , nativeMonitor = productionMonitors
    }

-- | The monitor operations, bound to GLFW.
productionMonitors ∷ MonitorNative
productionMonitors =
  MonitorNative
    { nativeMonitors = alloca $ \count → do
        array ← c_glfwGetMonitors count
        reported ← peek count
        counted array reported (\copied → peekArray copied array)
    , nativePrimaryMonitor = c_glfwGetPrimaryMonitor
    , nativeMonitorName = \monitor → do
        name ← c_glfwGetMonitorName monitor
        if name == nullPtr
          then pure Nothing
          else Just . decodeUtf8Lenient <$> ByteString.packCString name
    , nativeMonitorPosition = pairOf c_glfwGetMonitorPos id
    , nativeMonitorWorkArea = \monitor →
        alloca $ \x → alloca $ \y → alloca $ \width → alloca $ \height → do
          c_glfwGetMonitorWorkarea monitor x y width height
          (,,,) <$> peek x <*> peek y <*> peek width <*> peek height
    , nativeMonitorPhysicalSize = pairOf c_glfwGetMonitorPhysicalSize id
    , nativeMonitorContentScale = pairOf c_glfwGetMonitorContentScale id
    , nativeMonitorCurrentMode = \monitor → do
        mode ← c_glfwGetVideoMode monitor
        if mode == nullPtr then pure Nothing else Just <$> videoModeAt mode 0
    , nativeMonitorVideoModes = \monitor →
        alloca $ \count → do
          modes ← c_glfwGetVideoModes monitor count
          reported ← peek count
          counted modes reported (\copied → mapM (videoModeAt modes) [0 .. copied - 1])
    , nativeNewMonitorCallback = fmap MonitorCallbackStorage . c_wrapMonitorCallback
    , nativeAttachMonitorCallback = \(MonitorCallbackStorage callback) →
        void (c_glfwSetMonitorCallback callback)
    , nativeDetachMonitorCallback = void (c_glfwSetMonitorCallback nullFunPtr)
    , nativeFreeMonitorCallback = \(MonitorCallbackStorage callback) → freeHaskellFunPtr callback
    , nativeMonitorConnected = glfwConnected
    , nativeMonitorDisconnected = glfwDisconnected
    }

-- | Copy a counted GLFW array: 'Nothing' for a negative count, or a positive
-- count beside a null array.
counted ∷ Ptr a → CInt → (Int → IO [b]) → IO (Maybe [b])
counted array count copy
  | count < 0 = pure Nothing
  | count == 0 = pure (Just [])
  | array == nullPtr = pure Nothing
  | otherwise = Just <$> copy (fromIntegral count)

-- | GLFW's video mode structure, only ever read through the shim.
data VideoModes

-- | Copy one video mode's fields.
videoModeAt ∷ Ptr VideoModes → Int → IO NativeVideoMode
videoModeAt modes index =
  allocaArray 6 $ \fields → do
    c_videoModeAt modes (fromIntegral index) fields
    NativeVideoMode
      <$> peekElemOff fields 0
      <*> peekElemOff fields 1
      <*> peekElemOff fields 2
      <*> peekElemOff fields 3
      <*> peekElemOff fields 4
      <*> peekElemOff fields 5

-- | The monitor callback GLFW currently holds, read by replacing it with none and
-- restoring it, for the native examples only.
installedMonitorCallbackForCheck ∷ IO MonitorCallbackStorage
installedMonitorCallbackForCheck = do
  installed ← c_glfwSetMonitorCallback nullFunPtr
  _ ← c_glfwSetMonitorCallback installed
  pure (MonitorCallbackStorage installed)

-- | The exclusivity guard for this process's one GLFW instance.
processGuard ∷ Guard
processGuard = unsafePerformIO newGuard
{-# NOINLINE processGuard #-}

hostBackend ∷ Maybe Backend
hostBackend = case os of
  "darwin" → Just Cocoa
  "linux" → Just X11
  _ → Nothing

platformCode ∷ Backend → CInt
platformCode X11 = glfwPlatformX11
platformCode Cocoa = glfwPlatformCocoa
platformCode Wayland = glfwPlatformWayland

platformBackend ∷ CInt → Maybe Backend
platformBackend code
  | code == glfwPlatformX11 = Just X11
  | code == glfwPlatformCocoa = Just Cocoa
  | code == glfwPlatformWayland = Just Wayland
  | otherwise = Nothing

setWindowHint ∷ WindowHint → IO ()
setWindowHint NoClientApi = c_glfwWindowHint glfwClientApi glfwNoApi
setWindowHint (VisibleHint visible) = c_glfwWindowHint glfwVisible (boolean visible)
setWindowHint (FocusedHint focused) = c_glfwWindowHint glfwFocused (boolean focused)
setWindowHint (FocusOnShowHint focusOnShow) = c_glfwWindowHint glfwFocusOnShow (boolean focusOnShow)

boolean ∷ Bool → CInt
boolean flag = if flag then glfwTrue else glfwFalse

attributeCode ∷ WindowAttribute → CInt
attributeCode FocusedAttribute = glfwFocused
attributeCode IconifiedAttribute = glfwIconified
attributeCode MaximizedAttribute = glfwMaximized
attributeCode VisibleAttribute = glfwVisible
attributeCode DecoratedAttribute = glfwDecorated

-- | Read a pair a GLFW getter writes through two out-pointers.
pairOf ∷ Storable c ⇒ (Ptr object → Ptr c → Ptr c → IO ()) → (c → a) → Ptr object → IO (a, a)
pairOf getter convert object =
  alloca $ \first → alloca $ \second → do
    getter object first second
    (,) <$> (convert <$> peek first) <*> (convert <$> peek second)

type PairCallback = Ptr NativeWindow → CInt → CInt → IO ()
type ScaleCallback = Ptr NativeWindow → CFloat → CFloat → IO ()
type FlagCallback = Ptr NativeWindow → CInt → IO ()
type PlainCallback = Ptr NativeWindow → IO ()

-- | Allocate one wrapper per callback, in 'WindowCallbacks' order. Each wrapper
-- only drops the window pointer; the model's callback is already contained. A
-- failure part-way frees the wrappers already allocated.
newWindowCallbacks ∷ WindowCallbacks → IO WindowCallbackStorage
newWindowCallbacks callbacks =
  WindowCallbackStorage . reverse
    <$> allocating
      []
      [ castFunPtr <$> c_wrapPairCallback (\_ width height → onWindowSize callbacks width height)
      , castFunPtr <$> c_wrapPairCallback (\_ width height → onFramebufferSize callbacks width height)
      , castFunPtr <$> c_wrapScaleCallback (\_ x y → onContentScale callbacks x y)
      , castFunPtr <$> c_wrapPairCallback (\_ x y → onWindowPosition callbacks x y)
      , castFunPtr <$> c_wrapFlagCallback (\_ focused → onWindowFocus callbacks focused)
      , castFunPtr <$> c_wrapFlagCallback (\_ iconified → onWindowIconify callbacks iconified)
      , castFunPtr <$> c_wrapFlagCallback (\_ maximized → onWindowMaximize callbacks maximized)
      , castFunPtr <$> c_wrapPlainCallback (\_ → onWindowRefresh callbacks)
      , castFunPtr <$> c_wrapPlainCallback (\_ → onWindowClose callbacks)
      ]
  where
    allocating done [] = pure done
    allocating done (next : rest) = do
      pointer ← next `onException` mapM_ freeHaskellFunPtr done
      allocating (pointer : done) rest

attachWindowCallbacks ∷ Ptr NativeWindow → WindowCallbackStorage → IO ()
attachWindowCallbacks window (WindowCallbackStorage [size, framebuffer, scale, position, focus, iconify, maximize, refresh, close]) = do
  void (c_glfwSetWindowSizeCallback window (castFunPtr size))
  void (c_glfwSetFramebufferSizeCallback window (castFunPtr framebuffer))
  void (c_glfwSetWindowContentScaleCallback window (castFunPtr scale))
  void (c_glfwSetWindowPosCallback window (castFunPtr position))
  void (c_glfwSetWindowFocusCallback window (castFunPtr focus))
  void (c_glfwSetWindowIconifyCallback window (castFunPtr iconify))
  void (c_glfwSetWindowMaximizeCallback window (castFunPtr maximize))
  void (c_glfwSetWindowRefreshCallback window (castFunPtr refresh))
  void (c_glfwSetWindowCloseCallback window (castFunPtr close))
attachWindowCallbacks _ _ = ioError (userError "window callback storage does not hold nine wrappers")

detachWindowCallbacks ∷ Ptr NativeWindow → IO ()
detachWindowCallbacks window = do
  void (c_glfwSetWindowSizeCallback window nullFunPtr)
  void (c_glfwSetFramebufferSizeCallback window nullFunPtr)
  void (c_glfwSetWindowContentScaleCallback window nullFunPtr)
  void (c_glfwSetWindowPosCallback window nullFunPtr)
  void (c_glfwSetWindowFocusCallback window nullFunPtr)
  void (c_glfwSetWindowIconifyCallback window nullFunPtr)
  void (c_glfwSetWindowMaximizeCallback window nullFunPtr)
  void (c_glfwSetWindowRefreshCallback window nullFunPtr)
  void (c_glfwSetWindowCloseCallback window nullFunPtr)

-- | Resize a window: a callback-producing setter for the native examples only.
setWindowSizeForCheck ∷ Ptr NativeWindow → Int → Int → IO ()
setWindowSizeForCheck window width height = c_glfwSetWindowSize window (fromIntegral width) (fromIntegral height)

-- | Process pending events once, for the native examples only.
pollEventsForCheck ∷ IO ()
pollEventsForCheck = c_glfwPollEvents

-- | Wait until an event arrives, or at most this many seconds, and process it,
-- for the native examples only. X11 delivers a window's configure event after a
-- round trip to the server rather than inside the setter, so an example waiting
-- for a callback the platform has yet to deliver waits here instead of spinning.
waitEventsForCheck ∷ Double → IO ()
waitEventsForCheck seconds = c_glfwWaitEventsTimeout (CDouble seconds)

-- | Ask the platform to close a window, as its close button would, for the
-- native examples only: @performClose:@ on Cocoa, and a @WM_DELETE_WINDOW@
-- client message on X11. GLFW reports the request through the window's close
-- callback — inside this call on Cocoa, and from a later event poll on X11 —
-- and destroys nothing.
requestCloseForCheck ∷ Ptr NativeWindow → IO ()
requestCloseForCheck = c_requestCloseForCheck

-- | Record progress in the production finite wait in progress, only while the
-- thread making it is blocked inside GLFW's wait, and wake that wait with an
-- empty event, for the native examples only. 'False' when no note landed.
noteProgressForCheck ∷ IO Bool
noteProgressForCheck = (/= 0) <$> c_noteProgressForCheck

-- | Whether a 'noteProgressForCheck' landed in the most recent production wait
-- to return, cleared by reading it, for the native examples only.
takeWaitNotedForCheck ∷ IO Bool
takeWaitNotedForCheck = (/= 0) <$> c_takeWaitNotedForCheck

-- | Set a creation hint no window configuration sets, so the native examples can
-- show that the next window's creation resets it.
leakResizableHintForCheck ∷ IO ()
leakResizableHintForCheck = c_glfwWindowHint glfwResizable glfwFalse

-- | Whether a window is resizable, for the native examples only.
windowResizableForCheck ∷ Ptr NativeWindow → IO Bool
windowResizableForCheck window = (/= glfwFalse) <$> c_glfwGetWindowAttrib window glfwResizable

-- | The window's logical size as GLFW reports it now, for the native examples
-- only: the test-only query they compare observations with.
windowSizeForCheck ∷ Ptr NativeWindow → IO (Int, Int)
windowSizeForCheck = pairOf c_glfwGetWindowSize fromIntegral

-- | The window's position as GLFW reports it now, for the native examples only.
windowPositionForCheck ∷ Ptr NativeWindow → IO (Int, Int)
windowPositionForCheck = pairOf c_glfwGetWindowPos fromIntegral

-- | The title GLFW holds for the window, copied, for the native examples only.
windowTitleForCheck ∷ Ptr NativeWindow → IO (Maybe Text)
windowTitleForCheck window = do
  title ← c_windowTitle window
  if title == nullPtr then pure Nothing else Just . decodeUtf8Lenient <$> ByteString.packCString title

-- | The size limits the platform itself holds for the window — minimum width and
-- height, then maximum width and height, 'Nothing' for a bound it does not
-- hold — for the native examples only. 'Nothing' when they could not be read.
sizeLimitsForCheck ∷ Ptr NativeWindow → IO (Maybe (Maybe Int, Maybe Int, Maybe Int, Maybe Int))
sizeLimitsForCheck window =
  allocaArray 4 $ \limits → do
    answered ← c_sizeLimitsForCheck window limits
    if answered == 0
      then pure Nothing
      else do
        [minimumWidth, minimumHeight, maximumWidth, maximumHeight] ← map bound <$> peekArray 4 limits
        pure (Just (minimumWidth, minimumHeight, maximumWidth, maximumHeight))
  where
    bound value = if value < 0 then Nothing else Just (fromIntegral value)

-- | Whether GLFW reports the window on a monitor now, for the native examples
-- only.
windowFullscreenForCheck ∷ Ptr NativeWindow → IO Bool
windowFullscreenForCheck window = (/= nullPtr) <$> c_glfwGetWindowMonitor window

-- | The window state attributes GLFW reports now, for the native examples only.
data WindowStateForCheck = WindowStateForCheck
  { checkVisible ∷ Bool
  , checkIconified ∷ Bool
  , checkMaximized ∷ Bool
  , checkFocused ∷ Bool
  , checkDecorated ∷ Bool
  }
  deriving (Eq, Show)

windowStateForCheck ∷ Ptr NativeWindow → IO WindowStateForCheck
windowStateForCheck window =
  WindowStateForCheck
    <$> attribute glfwVisible
    <*> attribute glfwIconified
    <*> attribute glfwMaximized
    <*> attribute glfwFocused
    <*> attribute glfwDecorated
  where
    attribute code = (/= glfwFalse) <$> c_glfwGetWindowAttrib window code

createWindow ∷ Int32 → Int32 → Text → IO (Ptr NativeWindow)
createWindow width height title =
  ByteString.useAsCString (encodeUtf8 title) $ \native →
    c_glfwCreateWindow (fromIntegral width) (fromIntegral height) native nullPtr nullPtr

foreign import capi unsafe "hetoimasia_glfw.h hetoimasia_glfw_is_process_main_thread"
  c_isProcessMainThread ∷ IO CInt

foreign import capi safe "hetoimasia_glfw.h hetoimasia_glfw_request_close_for_check"
  c_requestCloseForCheck ∷ Ptr NativeWindow → IO ()

-- The production finite wait goes through the shim, which records what the
-- native examples observe of it and then calls glfwWaitEventsTimeout.
foreign import capi safe "hetoimasia_glfw.h hetoimasia_glfw_wait_events_timeout"
  c_waitEventsTimeout ∷ CDouble → IO ()

foreign import capi safe "hetoimasia_glfw.h hetoimasia_glfw_note_progress_for_check"
  c_noteProgressForCheck ∷ IO CInt

foreign import capi safe "hetoimasia_glfw.h hetoimasia_glfw_take_wait_noted_for_check"
  c_takeWaitNotedForCheck ∷ IO CInt

foreign import capi safe "hetoimasia_glfw.h glfwPlatformSupported"
  c_glfwPlatformSupported ∷ CInt → IO CInt

foreign import ccall safe "glfwSetErrorCallback"
  c_glfwSetErrorCallback ∷ FunPtr ErrorCallback → IO (FunPtr ErrorCallback)

foreign import ccall "wrapper"
  c_wrapErrorCallback ∷ ErrorCallback → IO (FunPtr ErrorCallback)

foreign import capi safe "hetoimasia_glfw.h glfwInitHint"
  c_glfwInitHint ∷ CInt → CInt → IO ()

foreign import capi safe "hetoimasia_glfw.h glfwInit"
  c_glfwInit ∷ IO CInt

foreign import capi safe "hetoimasia_glfw.h glfwGetPlatform"
  c_glfwGetPlatform ∷ IO CInt

foreign import capi safe "hetoimasia_glfw.h glfwTerminate"
  c_glfwTerminate ∷ IO ()

foreign import capi safe "hetoimasia_glfw.h glfwDefaultWindowHints"
  c_glfwDefaultWindowHints ∷ IO ()

foreign import capi safe "hetoimasia_glfw.h glfwWindowHint"
  c_glfwWindowHint ∷ CInt → CInt → IO ()

foreign import capi safe "hetoimasia_glfw.h glfwCreateWindow"
  c_glfwCreateWindow ∷ CInt → CInt → CString → Ptr () → Ptr NativeWindow → IO (Ptr NativeWindow)

foreign import capi safe "hetoimasia_glfw.h glfwDestroyWindow"
  c_glfwDestroyWindow ∷ Ptr NativeWindow → IO ()

foreign import capi safe "hetoimasia_glfw.h glfwGetWindowSize"
  c_glfwGetWindowSize ∷ Ptr NativeWindow → Ptr CInt → Ptr CInt → IO ()

foreign import capi safe "hetoimasia_glfw.h glfwGetFramebufferSize"
  c_glfwGetFramebufferSize ∷ Ptr NativeWindow → Ptr CInt → Ptr CInt → IO ()

foreign import capi safe "hetoimasia_glfw.h glfwGetWindowContentScale"
  c_glfwGetWindowContentScale ∷ Ptr NativeWindow → Ptr CFloat → Ptr CFloat → IO ()

foreign import capi safe "hetoimasia_glfw.h glfwGetWindowPos"
  c_glfwGetWindowPos ∷ Ptr NativeWindow → Ptr CInt → Ptr CInt → IO ()

foreign import capi safe "hetoimasia_glfw.h glfwGetWindowAttrib"
  c_glfwGetWindowAttrib ∷ Ptr NativeWindow → CInt → IO CInt

foreign import capi safe "hetoimasia_glfw.h glfwSetWindowSize"
  c_glfwSetWindowSize ∷ Ptr NativeWindow → CInt → CInt → IO ()

foreign import capi safe "hetoimasia_glfw.h glfwSetWindowTitle"
  c_glfwSetWindowTitle ∷ Ptr NativeWindow → CString → IO ()

foreign import capi safe "hetoimasia_glfw.h hetoimasia_glfw_window_title"
  c_windowTitle ∷ Ptr NativeWindow → IO CString

foreign import capi safe "hetoimasia_glfw.h hetoimasia_glfw_size_limits_for_check"
  c_sizeLimitsForCheck ∷ Ptr NativeWindow → Ptr CInt → IO CInt

foreign import capi safe "hetoimasia_glfw.h glfwSetWindowPos"
  c_glfwSetWindowPos ∷ Ptr NativeWindow → CInt → CInt → IO ()

foreign import capi safe "hetoimasia_glfw.h glfwSetWindowSizeLimits"
  c_glfwSetWindowSizeLimits ∷ Ptr NativeWindow → CInt → CInt → CInt → CInt → IO ()

foreign import capi safe "hetoimasia_glfw.h glfwSetWindowAspectRatio"
  c_glfwSetWindowAspectRatio ∷ Ptr NativeWindow → CInt → CInt → IO ()

foreign import capi safe "hetoimasia_glfw.h glfwShowWindow"
  c_glfwShowWindow ∷ Ptr NativeWindow → IO ()

foreign import capi safe "hetoimasia_glfw.h glfwHideWindow"
  c_glfwHideWindow ∷ Ptr NativeWindow → IO ()

foreign import capi safe "hetoimasia_glfw.h glfwFocusWindow"
  c_glfwFocusWindow ∷ Ptr NativeWindow → IO ()

foreign import capi safe "hetoimasia_glfw.h glfwRequestWindowAttention"
  c_glfwRequestWindowAttention ∷ Ptr NativeWindow → IO ()

foreign import capi safe "hetoimasia_glfw.h glfwIconifyWindow"
  c_glfwIconifyWindow ∷ Ptr NativeWindow → IO ()

foreign import capi safe "hetoimasia_glfw.h glfwMaximizeWindow"
  c_glfwMaximizeWindow ∷ Ptr NativeWindow → IO ()

foreign import capi safe "hetoimasia_glfw.h glfwRestoreWindow"
  c_glfwRestoreWindow ∷ Ptr NativeWindow → IO ()

foreign import capi safe "hetoimasia_glfw.h glfwGetWindowMonitor"
  c_glfwGetWindowMonitor ∷ Ptr NativeWindow → IO (Ptr NativeMonitor)

foreign import capi safe "hetoimasia_glfw.h glfwSetWindowMonitor"
  c_glfwSetWindowMonitor ∷ Ptr NativeWindow → Ptr NativeMonitor → CInt → CInt → CInt → CInt → CInt → IO ()

foreign import capi safe "hetoimasia_glfw.h glfwSetWindowAttrib"
  c_glfwSetWindowAttrib ∷ Ptr NativeWindow → CInt → CInt → IO ()

foreign import capi safe "hetoimasia_glfw.h glfwPollEvents"
  c_glfwPollEvents ∷ IO ()

foreign import capi safe "hetoimasia_glfw.h glfwWaitEventsTimeout"
  c_glfwWaitEventsTimeout ∷ CDouble → IO ()

foreign import capi safe "hetoimasia_glfw.h hetoimasia_glfw_monitors"
  c_glfwGetMonitors ∷ Ptr CInt → IO (Ptr (Ptr NativeMonitor))

foreign import capi safe "hetoimasia_glfw.h glfwGetPrimaryMonitor"
  c_glfwGetPrimaryMonitor ∷ IO (Ptr NativeMonitor)

foreign import capi safe "hetoimasia_glfw.h hetoimasia_glfw_monitor_name"
  c_glfwGetMonitorName ∷ Ptr NativeMonitor → IO CString

foreign import capi safe "hetoimasia_glfw.h glfwGetMonitorPos"
  c_glfwGetMonitorPos ∷ Ptr NativeMonitor → Ptr CInt → Ptr CInt → IO ()

foreign import capi safe "hetoimasia_glfw.h glfwGetMonitorWorkarea"
  c_glfwGetMonitorWorkarea ∷ Ptr NativeMonitor → Ptr CInt → Ptr CInt → Ptr CInt → Ptr CInt → IO ()

foreign import capi safe "hetoimasia_glfw.h glfwGetMonitorPhysicalSize"
  c_glfwGetMonitorPhysicalSize ∷ Ptr NativeMonitor → Ptr CInt → Ptr CInt → IO ()

foreign import capi safe "hetoimasia_glfw.h glfwGetMonitorContentScale"
  c_glfwGetMonitorContentScale ∷ Ptr NativeMonitor → Ptr CFloat → Ptr CFloat → IO ()

foreign import capi safe "hetoimasia_glfw.h hetoimasia_glfw_video_mode"
  c_glfwGetVideoMode ∷ Ptr NativeMonitor → IO (Ptr VideoModes)

foreign import capi safe "hetoimasia_glfw.h hetoimasia_glfw_video_modes"
  c_glfwGetVideoModes ∷ Ptr NativeMonitor → Ptr CInt → IO (Ptr VideoModes)

-- The copier reads the structure and calls nothing.
foreign import capi unsafe "hetoimasia_glfw.h hetoimasia_glfw_video_mode_at"
  c_videoModeAt ∷ Ptr VideoModes → CInt → Ptr CInt → IO ()

foreign import ccall safe "glfwSetMonitorCallback"
  c_glfwSetMonitorCallback ∷ FunPtr MonitorCallback → IO (FunPtr MonitorCallback)

foreign import ccall "wrapper"
  c_wrapMonitorCallback ∷ MonitorCallback → IO (FunPtr MonitorCallback)

foreign import ccall "wrapper"
  c_wrapPairCallback ∷ PairCallback → IO (FunPtr PairCallback)

foreign import ccall "wrapper"
  c_wrapScaleCallback ∷ ScaleCallback → IO (FunPtr ScaleCallback)

foreign import ccall "wrapper"
  c_wrapFlagCallback ∷ FlagCallback → IO (FunPtr FlagCallback)

foreign import ccall "wrapper"
  c_wrapPlainCallback ∷ PlainCallback → IO (FunPtr PlainCallback)

foreign import ccall safe "glfwSetWindowSizeCallback"
  c_glfwSetWindowSizeCallback ∷ Ptr NativeWindow → FunPtr PairCallback → IO (FunPtr PairCallback)

foreign import ccall safe "glfwSetFramebufferSizeCallback"
  c_glfwSetFramebufferSizeCallback ∷ Ptr NativeWindow → FunPtr PairCallback → IO (FunPtr PairCallback)

foreign import ccall safe "glfwSetWindowContentScaleCallback"
  c_glfwSetWindowContentScaleCallback ∷ Ptr NativeWindow → FunPtr ScaleCallback → IO (FunPtr ScaleCallback)

foreign import ccall safe "glfwSetWindowPosCallback"
  c_glfwSetWindowPosCallback ∷ Ptr NativeWindow → FunPtr PairCallback → IO (FunPtr PairCallback)

foreign import ccall safe "glfwSetWindowFocusCallback"
  c_glfwSetWindowFocusCallback ∷ Ptr NativeWindow → FunPtr FlagCallback → IO (FunPtr FlagCallback)

foreign import ccall safe "glfwSetWindowIconifyCallback"
  c_glfwSetWindowIconifyCallback ∷ Ptr NativeWindow → FunPtr FlagCallback → IO (FunPtr FlagCallback)

foreign import ccall safe "glfwSetWindowMaximizeCallback"
  c_glfwSetWindowMaximizeCallback ∷ Ptr NativeWindow → FunPtr FlagCallback → IO (FunPtr FlagCallback)

foreign import ccall safe "glfwSetWindowRefreshCallback"
  c_glfwSetWindowRefreshCallback ∷ Ptr NativeWindow → FunPtr PlainCallback → IO (FunPtr PlainCallback)

foreign import ccall safe "glfwSetWindowCloseCallback"
  c_glfwSetWindowCloseCallback ∷ Ptr NativeWindow → FunPtr PlainCallback → IO (FunPtr PlainCallback)

foreign import capi "hetoimasia_glfw.h value GLFW_TRUE" glfwTrue ∷ CInt
foreign import capi "hetoimasia_glfw.h value GLFW_FALSE" glfwFalse ∷ CInt
foreign import capi "hetoimasia_glfw.h value GLFW_PLATFORM" glfwPlatformHint ∷ CInt
foreign import capi "hetoimasia_glfw.h value GLFW_PLATFORM_X11" glfwPlatformX11 ∷ CInt
foreign import capi "hetoimasia_glfw.h value GLFW_PLATFORM_COCOA" glfwPlatformCocoa ∷ CInt
foreign import capi "hetoimasia_glfw.h value GLFW_PLATFORM_WAYLAND" glfwPlatformWayland ∷ CInt
foreign import capi "hetoimasia_glfw.h value GLFW_COCOA_CHDIR_RESOURCES" glfwCocoaChdirResources ∷ CInt
foreign import capi "hetoimasia_glfw.h value GLFW_CLIENT_API" glfwClientApi ∷ CInt
foreign import capi "hetoimasia_glfw.h value GLFW_NO_API" glfwNoApi ∷ CInt
foreign import capi "hetoimasia_glfw.h value GLFW_VISIBLE" glfwVisible ∷ CInt
foreign import capi "hetoimasia_glfw.h value GLFW_FOCUSED" glfwFocused ∷ CInt
foreign import capi "hetoimasia_glfw.h value GLFW_FOCUS_ON_SHOW" glfwFocusOnShow ∷ CInt
foreign import capi "hetoimasia_glfw.h value GLFW_ICONIFIED" glfwIconified ∷ CInt
foreign import capi "hetoimasia_glfw.h value GLFW_MAXIMIZED" glfwMaximized ∷ CInt
foreign import capi "hetoimasia_glfw.h value GLFW_RESIZABLE" glfwResizable ∷ CInt
foreign import capi "hetoimasia_glfw.h value GLFW_DECORATED" glfwDecorated ∷ CInt
foreign import capi "hetoimasia_glfw.h value GLFW_DONT_CARE" glfwDontCare ∷ CInt
foreign import capi "hetoimasia_glfw.h value GLFW_CONNECTED" glfwConnected ∷ CInt
foreign import capi "hetoimasia_glfw.h value GLFW_DISCONNECTED" glfwDisconnected ∷ CInt

-- | @GLFW_FEATURE_UNAVAILABLE@, the error a query reports for a property the
-- platform cannot provide.
foreign import capi "hetoimasia_glfw.h value GLFW_FEATURE_UNAVAILABLE" glfwFeatureUnavailable ∷ CInt

-- | @GLFW_PLATFORM_UNAVAILABLE@, the error an initialization requesting a
-- platform this library was not built with reports.
foreign import capi "hetoimasia_glfw.h value GLFW_PLATFORM_UNAVAILABLE" glfwPlatformUnavailable ∷ CInt
