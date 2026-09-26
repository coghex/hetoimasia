-- | The Wayland connection-status probe's vocabulary, and the terminal failure
-- a confirmed loss raises.
--
-- GLFW 3.4's Wayland event loop reports a lost compositor connection through no
-- error at all: when its display flush fails it cancels the read, issues a close
-- request for every window, and returns. A close request is therefore neither
-- necessary nor sufficient evidence that the connection ended, and an
-- application may reject ordinary close requests. Under the Wayland
-- qualification design's D-13 the production native shim instead carries a
-- private, read-only probe: it reads the display's latched error and the
-- status of its socket with a zero-timeout @poll@, dispatches nothing, flushes
-- nothing, and answers a copied 'ConnectionStatus'. GLFW stays the
-- connection's owner; the engine receives a status and applications never a
-- handle.
--
-- The session resolves the probe once, at entry, on Wayland only, and a
-- library that cannot supply one refuses the Wayland session with
-- 'ConnectionProbeUnavailable'. Event processing consults it before and after
-- every native poll or wait, with or without windows, and a status other than
-- healthy fails that processing with 'ConnectionFailed'. The failure is
-- terminal under D-10: the session latches it, never probes or pumps again,
-- and never reconnects. X11 and Cocoa sessions resolve no probe and make no
-- probe call.
--
-- Nothing here is exported by a public module except 'ConnectionFailed' and
-- 'ConnectionCause', which are how an application observes the session
-- failure. 'ConnectionProbe' and 'ConnectionStatus' stay private.
module Hetoimasia.GLFW.Internal.Connection
  ( -- * The probe
    ConnectionProbe (..)
  , ConnectionStatus (..)
  , ConnectionCause (..)
  , EventBoundary (..)

    -- * Failures
  , ConnectionFailed (..)
  , ConnectionProbeUnavailable (..)
  ) where

import Control.Exception (Exception (displayException))
import Data.Text (Text)
import qualified Data.Text as Text
import Hetoimasia.GLFW.Internal.Capture (Reports, hasReports)

-- | One zero-timeout status read of the session's display connection, made on
-- the owner thread. It reads, and never dispatches, flushes, or waits.
newtype ConnectionProbe = ConnectionProbe (IO ConnectionStatus)

-- | What one probe found.
data ConnectionStatus
  = ConnectionHealthy
    -- ^ No error is latched on the display, and its socket reports no closure.
  | ConnectionEnded !ConnectionCause
  deriving (Eq, Show)

-- | Why a connection can no longer be used. The three are reported as
-- themselves, and none of them is described as the compositor having crashed:
-- the probe establishes what the client can see, not why it happened.
data ConnectionCause
  = TransportClosed !(Maybe Int)
    -- ^ The socket's peer closed it, or the display latched a transport error:
    -- the @errno@ the display latched, or 'Nothing' when only the socket
    -- reported the closure.
  | ProtocolFailure
    -- ^ The display latched a protocol error (@EPROTO@): the compositor
    -- reported a fatal protocol violation and closed the connection's use.
  | ProbeFailure !Text
    -- ^ The probe could not establish the status at all, and says why. The
    -- connection can no longer be vouched for, which is not the same claim as
    -- its having ended.
  deriving (Eq, Show)

-- | Where the probe ran, relative to the native poll or wait.
data EventBoundary
  = BeforeEvents
  | AfterEvents
  deriving (Eq, Show)

-- | Event processing found the session's display connection unusable, and the
-- session is terminal: every later event processing raises this same failure
-- without a native call, and nothing reconnects.
data ConnectionFailed = ConnectionFailed
  { connectionCause ∷ !ConnectionCause
  , connectionBoundary ∷ !EventBoundary
    -- ^ The boundary whose probe first found it.
  , connectionReports ∷ !Reports
    -- ^ What GLFW reported on the owner thread during that event processing,
    -- kept beside the cause rather than raised in its place.
  }
  deriving (Eq, Show)

instance Exception ConnectionFailed where
  displayException failure =
    Text.unpack (causeText (connectionCause failure))
      <> ", found "
      <> boundaryText (connectionBoundary failure)
      <> "; the session is terminal and does not reconnect"
      <> if hasReports (connectionReports failure)
        then "; GLFW also reported " <> show (connectionReports failure)
        else ""
    where
      boundaryText BeforeEvents = "before event processing"
      boundaryText AfterEvents = "after event processing"

causeText ∷ ConnectionCause → Text
causeText = \case
  TransportClosed Nothing → "the Wayland connection's transport closed: its socket reports the peer gone"
  TransportClosed (Just code) → "the Wayland connection's transport closed: the display latched errno " <> Text.pack (show code)
  ProtocolFailure → "the Wayland connection failed with a protocol error the display latched"
  ProbeFailure reason → "the Wayland connection-status probe failed, so the connection can no longer be vouched for: " <> reason

-- | This library cannot supply the connection-status probe a Wayland session
-- requires, and says why. Entry fails with it, attributed to initialization,
-- once GLFW has initialized and before the session is lent to anyone; the
-- rollback terminates GLFW.
newtype ConnectionProbeUnavailable = ConnectionProbeUnavailable Text
  deriving (Eq, Show)

instance Exception ConnectionProbeUnavailable where
  displayException (ConnectionProbeUnavailable reason) =
    "a Wayland session requires the connection-status probe, and this library cannot supply it: "
      <> Text.unpack reason
      <> "; without it a lost compositor connection could not be confirmed, so the session is refused"
