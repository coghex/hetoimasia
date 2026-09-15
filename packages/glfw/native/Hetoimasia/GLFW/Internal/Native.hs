{-# LANGUAGE CApiFFI #-}

-- | The private binding to upstream GLFW 3.4, and the production native table.
--
-- Only the operations the session and window models use are bound. Every function and
-- constant is imported through @hetoimasia_glfw.h@, which includes the
-- installed @GLFW/glfw3.h@, so the C compiler checks each declaration and every
-- constant's value comes from the header rather than from a copied number. The
-- exceptions are @glfwSetErrorCallback@ and the window callback setters,
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
  , setWindowSizeForCheck
  , pollEventsForCheck
  , leakResizableHintForCheck
  , windowResizableForCheck
  ) where

import Control.Exception (onException)
import Control.Monad (void)
import qualified Data.ByteString as ByteString
import Data.Int (Int32)
import Data.Text (Text)
import Data.Text.Encoding (encodeUtf8)
import Foreign.C.String (CString)
import Foreign.C.Types (CFloat (CFloat), CInt (CInt))
import Foreign.Marshal.Alloc (alloca)
import Foreign.Ptr (FunPtr, Ptr, castFunPtr, freeHaskellFunPtr, nullFunPtr, nullPtr)
import Foreign.Storable (Storable, peek)
import Hetoimasia.GLFW.Internal.Capture (ErrorCallback)
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
    , nativeFeatureUnavailable = fromIntegral glfwFeatureUnavailable
    }

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

-- | Read a pair a GLFW getter writes through two out-pointers.
pairOf ∷ Storable c ⇒ (Ptr NativeWindow → Ptr c → Ptr c → IO ()) → (c → a) → Ptr NativeWindow → IO (a, a)
pairOf getter convert window =
  alloca $ \first → alloca $ \second → do
    getter window first second
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

-- | Set a creation hint no window configuration sets, so the native examples can
-- show that the next window's creation resets it.
leakResizableHintForCheck ∷ IO ()
leakResizableHintForCheck = c_glfwWindowHint glfwResizable glfwFalse

-- | Whether a window is resizable, for the native examples only.
windowResizableForCheck ∷ Ptr NativeWindow → IO Bool
windowResizableForCheck window = (/= glfwFalse) <$> c_glfwGetWindowAttrib window glfwResizable

createWindow ∷ Int32 → Int32 → Text → IO (Ptr NativeWindow)
createWindow width height title =
  ByteString.useAsCString (encodeUtf8 title) $ \native →
    c_glfwCreateWindow (fromIntegral width) (fromIntegral height) native nullPtr nullPtr

foreign import capi unsafe "hetoimasia_glfw.h hetoimasia_glfw_is_process_main_thread"
  c_isProcessMainThread ∷ IO CInt

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

foreign import capi safe "hetoimasia_glfw.h glfwPollEvents"
  c_glfwPollEvents ∷ IO ()

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

-- | @GLFW_FEATURE_UNAVAILABLE@, the error a query reports for a property the
-- platform cannot provide.
foreign import capi "hetoimasia_glfw.h value GLFW_FEATURE_UNAVAILABLE" glfwFeatureUnavailable ∷ CInt

-- | @GLFW_PLATFORM_UNAVAILABLE@, the error an initialization requesting a
-- platform this library was not built with reports.
foreign import capi "hetoimasia_glfw.h value GLFW_PLATFORM_UNAVAILABLE" glfwPlatformUnavailable ∷ CInt
