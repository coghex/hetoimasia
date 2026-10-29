-- | A test-only way to make the platform deliver a genuine close request to a window (LFE-18).
--
-- 'requestNativeClose' asks the platform to close a window as its close button would: the window's own
-- close callback latches the request and numbers it in the window's observations, so a test can
-- qualify that an application routes a genuine close, as distinct from a close its own cleanup begins.
--
-- It is addressed by 'WindowId' through the host and runs on the session's owner (main) thread. It
-- answers whether a request was delivered and answers unavailable on a backend that exposes no handle
-- for it. It exports no native handle and no ABI declaration, and no production library depends on
-- this one: only test suites do. @injectCloseForCheck@ is not this: it invokes the registered callback
-- and is labelled injected.
module Hetoimasia.GLFW.NativeCheck
  ( NativeCloseAnswer (..)
  , requestNativeClose
  ) where

import Hetoimasia.GLFW.Internal.Native (requestCloseForCheck)
import Hetoimasia.GLFW.Internal.NativeCheck (NativeCloseAnswer (..), requestNativeCloseWith)
import Hetoimasia.GLFW.Window (WindowId)
import Hetoimasia.Runtime.GLFW (WindowHost)

-- | Ask the platform to close this window, on the owner thread. See the module header.
requestNativeClose ∷ WindowHost → WindowId → IO NativeCloseAnswer
requestNativeClose = requestNativeCloseWith requestCloseForCheck
