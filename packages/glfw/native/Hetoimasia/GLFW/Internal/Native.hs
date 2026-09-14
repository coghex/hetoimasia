{-# LANGUAGE CApiFFI #-}

-- | The private binding to upstream GLFW 3.4, and the production native table.
--
-- Only the operations the session model uses are bound. Every function and
-- constant is imported through @hetoimasia_glfw.h@, which includes the
-- installed @GLFW/glfw3.h@, so the C compiler checks each declaration and every
-- constant's value comes from the header rather than from a copied number. The
-- one exception is @glfwSetErrorCallback@, imported with @ccall@: its argument
-- is a function pointer whose C type the CAPI wrapper cannot spell, and it is
-- passed and returned as a plain pointer.
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
  ) where

import Control.Monad (void)
import qualified Data.ByteString as ByteString
import Data.Int (Int32)
import Data.Text (Text)
import Data.Text.Encoding (encodeUtf8)
import Foreign.C.String (CString)
import Foreign.C.Types (CInt (CInt))
import Foreign.Ptr (FunPtr, Ptr, freeHaskellFunPtr, nullFunPtr, nullPtr)
import Hetoimasia.GLFW.Internal.Capture (ErrorCallback)
import Hetoimasia.GLFW.Internal.Session
  ( Backend (..)
  , CallbackStorage (CallbackStorage)
  , Guard
  , Native (..)
  , NativeWindow
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
setWindowHint NotVisible = c_glfwWindowHint glfwVisible glfwFalse
setWindowHint NotFocused = c_glfwWindowHint glfwFocused glfwFalse
setWindowHint NoFocusOnShow = c_glfwWindowHint glfwFocusOnShow glfwFalse

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
