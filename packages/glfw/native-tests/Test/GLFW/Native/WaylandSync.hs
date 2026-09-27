{-# LANGUAGE CApiFFI #-}

-- | Test-only synchronization with the Wayland compositor, for the native
-- examples alone.
--
-- Both operations do what the Wayland qualification design's D-13 forbids the
-- production shim, which may only read the connection's status: they flush
-- GLFW's connection, and the barrier also reads and dispatches protocol
-- messages. So they are bound here, in the test suite's own C source
-- (@native-tests/cbits/hetoimasia_glfw_test.c@), and no library reaches them.
-- Each is a @safe@ call, because each can block on the compositor, and each
-- must run on the live Wayland session's owner thread, through the shared
-- fixture's 'Test.GLFW.Native.Support.owned'. Neither hands back a native
-- pointer or descriptor, and neither posts a GLFW empty event or touches the
-- production wait's records. A helper that cannot do its work fails the
-- example; neither falls back to anything weaker.
module Test.GLFW.Native.WaylandSync
  ( awaitCompositor
  , flushAndAwaitReply
  ) where

import Data.Maybe (fromMaybe)
import Foreign.C.Types (CInt (..))
import Foreign.Marshal.Alloc (alloca)
import Foreign.Ptr (Ptr)
import Foreign.Storable (peek)
import Test.GLFW.Native.Support (failed)

-- | Block until the compositor has processed every request the client sent
-- before this call, and every event those requests caused has been read. Events
-- addressed to the connection itself, such as the @delete_id@ that answers each
-- destroyed object, are dispatched here; events for GLFW's own objects are left
-- queued for the next event processing to dispatch.
awaitCompositor ∷ IO ()
awaitCompositor = helper "the compositor barrier" c_barrier

-- | Send everything the client has queued, then block for at most @seconds@
-- until the compositor's socket has something to read, reading nothing. It
-- establishes that an answer is waiting unread, without a sleep; one that has
-- not arrived in time fails the example.
flushAndAwaitReply ∷ Double → IO ()
flushAndAwaitReply seconds =
  helper "waiting for the compositor's reply" (c_flushAndAwaitReply (round (seconds * 1000)))

helper ∷ String → (Ptr CInt → IO CInt) → IO ()
helper name call =
  alloca $ \errorCode → do
    status ← call errorCode
    errno ← peek errorCode
    if status == testReady
      then pure ()
      else failed (name <> " " <> describe status <> errnoNote errno)
  where
    errnoNote errno = if errno == 0 then "" else " (errno " <> show errno <> ")"

describe ∷ CInt → String
describe status =
  fromMaybe ("answered an unknown status " <> show status) (lookup status reasons)
  where
    reasons =
      [ (testNoLibrary, "could not open libwayland-client")
      , (testNoSymbol, "could not resolve a libwayland-client symbol")
      , (testNotWayland, "ran on a session that did not select Wayland")
      , (testNoDisplay, "found no Wayland display")
      , (testFailed, "failed")
      , (testTimedOut, "timed out")
      , (testHangup, "found the compositor's socket closed")
      , (testUnsupportedPlatform, "is unavailable on a platform with no Wayland backend")
      ]

foreign import capi safe "hetoimasia_glfw_test.h hetoimasia_glfw_test_wayland_barrier"
  c_barrier ∷ Ptr CInt → IO CInt

foreign import capi safe "hetoimasia_glfw_test.h hetoimasia_glfw_test_wayland_flush_and_await_reply"
  c_flushAndAwaitReply ∷ CInt → Ptr CInt → IO CInt

foreign import capi "hetoimasia_glfw_test.h value HETOIMASIA_TEST_READY" testReady ∷ CInt
foreign import capi "hetoimasia_glfw_test.h value HETOIMASIA_TEST_NO_LIBRARY" testNoLibrary ∷ CInt
foreign import capi "hetoimasia_glfw_test.h value HETOIMASIA_TEST_NO_SYMBOL" testNoSymbol ∷ CInt
foreign import capi "hetoimasia_glfw_test.h value HETOIMASIA_TEST_NOT_WAYLAND" testNotWayland ∷ CInt
foreign import capi "hetoimasia_glfw_test.h value HETOIMASIA_TEST_NO_DISPLAY" testNoDisplay ∷ CInt
foreign import capi "hetoimasia_glfw_test.h value HETOIMASIA_TEST_FAILED" testFailed ∷ CInt
foreign import capi "hetoimasia_glfw_test.h value HETOIMASIA_TEST_TIMED_OUT" testTimedOut ∷ CInt
foreign import capi "hetoimasia_glfw_test.h value HETOIMASIA_TEST_HANGUP" testHangup ∷ CInt
foreign import capi "hetoimasia_glfw_test.h value HETOIMASIA_TEST_UNSUPPORTED_PLATFORM" testUnsupportedPlatform ∷ CInt
