{-# LANGUAGE CApiFFI #-}

-- | Test-only synchronization with the Wayland compositor, for the native
-- examples alone.
--
-- The barrier does what the Wayland qualification design's D-13 forbids the
-- production shim, which may only read the connection's status: it flushes
-- GLFW's connection, and reads and dispatches protocol messages. So it and its
-- observation are bound here, in the test suite's own C source
-- (@native-tests/cbits/hetoimasia_glfw_test.c@), and no library reaches them.
-- The barrier is a @safe@ call, because it blocks on the compositor, and must
-- run on the live Wayland session's owner thread — through the shared
-- fixture's 'Test.GLFW.Native.Support.owned', or in a private child on the
-- thread that entered its session. It hands back no native pointer or
-- descriptor, posts no GLFW empty event, and touches none of the production
-- wait's records; if it cannot do its work it fails the example, never falling
-- back to anything weaker. Its blocked observation reads only the barrier's own
-- sequence and the kernel's report of the thread running it.
module Test.GLFW.Native.WaylandSync
  ( awaitCompositor
  , blockedBarrierForCheck
  ) where

import Data.Maybe (fromMaybe)
import Foreign.C.Types (CInt (..), CULong (..))
import Foreign.Marshal.Alloc (alloca)
import Foreign.Ptr (Ptr)
import Foreign.Storable (peek)
import Numeric.Natural (Natural)
import Test.GLFW.Native.Support (failed)

-- | Block until the compositor has processed every request the client sent
-- before this call, and every event those requests caused has been read. Events
-- addressed to the connection itself, such as the @delete_id@ that answers each
-- destroyed object, are dispatched here; events for GLFW's own objects are left
-- queued for the next event processing to dispatch.
awaitCompositor ∷ IO ()
awaitCompositor = helper "the compositor barrier" c_barrier

-- | The odd sequence number of the barrier in progress, if the thread running
-- it is blocked in the kernel, observed as the production shim observes a
-- blocked wait. It observes and posts nothing, and may be called from any
-- thread.
blockedBarrierForCheck ∷ IO (Maybe Natural)
blockedBarrierForCheck = do
  sequenceNumber ← c_blockedBarrier
  pure (if sequenceNumber == 0 then Nothing else Just (fromIntegral sequenceNumber))

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
      , (testUnsupportedPlatform, "is unavailable on a platform with no Wayland backend")
      ]

foreign import capi safe "hetoimasia_glfw_test.h hetoimasia_glfw_test_wayland_barrier"
  c_barrier ∷ Ptr CInt → IO CInt

foreign import capi unsafe "hetoimasia_glfw_test.h hetoimasia_glfw_test_blocked_barrier"
  c_blockedBarrier ∷ IO CULong

foreign import capi "hetoimasia_glfw_test.h value HETOIMASIA_TEST_READY" testReady ∷ CInt
foreign import capi "hetoimasia_glfw_test.h value HETOIMASIA_TEST_NO_LIBRARY" testNoLibrary ∷ CInt
foreign import capi "hetoimasia_glfw_test.h value HETOIMASIA_TEST_NO_SYMBOL" testNoSymbol ∷ CInt
foreign import capi "hetoimasia_glfw_test.h value HETOIMASIA_TEST_NOT_WAYLAND" testNotWayland ∷ CInt
foreign import capi "hetoimasia_glfw_test.h value HETOIMASIA_TEST_NO_DISPLAY" testNoDisplay ∷ CInt
foreign import capi "hetoimasia_glfw_test.h value HETOIMASIA_TEST_FAILED" testFailed ∷ CInt
foreign import capi "hetoimasia_glfw_test.h value HETOIMASIA_TEST_UNSUPPORTED_PLATFORM" testUnsupportedPlatform ∷ CInt
