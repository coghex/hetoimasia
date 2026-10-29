-- | The test-only genuine native close (LFE-18): the implementation behind 'Hetoimasia.GLFW.NativeCheck',
-- written over a driver so the boundary can be examined without GLFW.
--
-- Closing a window as its close button does is a platform request: Cocoa @performClose:@ or an X11
-- @WM_DELETE_WINDOW@ client message, delivered to the window the host holds under a given 'WindowId'.
-- It must run on the session's owner thread, where the host lends a window, and it is the one way a
-- test can make the platform produce a close request without a person. The request it makes is then
-- latched by the window's own close callback and numbered in the window's observations, exactly as a
-- user's is; nothing is injected.
--
-- This module takes the driver as an argument, which is why it is private: its type names the native
-- window pointer. The public module applies the production driver and exports no native handle.
module Hetoimasia.GLFW.Internal.NativeCheck
  ( NativeCloseAnswer (..)
  , requestNativeCloseWith
  ) where

import Data.Functor ((<&>))
import Foreign.Ptr (Ptr)
import Hetoimasia.GLFW.Internal.Session (NativeWindow)
import Hetoimasia.GLFW.Internal.Window (WindowResult (..), windowNativeHandle)
import Hetoimasia.GLFW.Window (WindowId)
import Hetoimasia.Runtime.GLFW (WindowHost, withHostWindow)

-- | What asking the platform to close a window came to.
data NativeCloseAnswer
  = -- | The platform accepted the request: the window's close callback will latch it.
    NativeCloseDelivered
  | -- | This session's backend exposes no handle the driver can reach (Wayland, for one). Nothing was
    -- sent, and nothing is claimed about whether closing works there.
    NativeCloseUnavailable
  | -- | The host holds no such window (it was never held, or it has ended). Nothing was sent.
    NativeCloseWindowEnded
  deriving (Eq, Show)

-- | Ask the platform, through this driver, to close the window the host holds under this identity. Must
-- run on the session's owner thread, like every lending of a host window; any other thread is refused by
-- the host before the driver is reached.
requestNativeCloseWith ∷ (Ptr NativeWindow → IO Bool) → WindowHost → WindowId → IO NativeCloseAnswer
requestNativeCloseWith driver host window =
  withHostWindow host window (driver . windowNativeHandle) <&> \case
    WindowEnded _ → NativeCloseWindowEnded
    WindowAvailable True → NativeCloseDelivered
    WindowAvailable False → NativeCloseUnavailable
