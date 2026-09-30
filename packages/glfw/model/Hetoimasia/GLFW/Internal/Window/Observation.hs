{-# LANGUAGE DeriveGeneric #-}

-- | The immutable observations a window publishes, and the phases of its
-- lifetime they record.
--
-- Values only. The owner thread builds, prepares, and publishes each
-- observation through the window's snapshot; any thread may read one. The
-- representation is private to this package: the field names are exported only
-- from this private module, for the window modules that fold and publish
-- observations, and "Hetoimasia.GLFW.Internal.Window" and the public API keep
-- the type abstract.
--
-- = Observations
--
-- A 'WindowObservation' is immutable and prepared to normal form before it is
-- published. It carries the window's identity, a revision equal to the
-- snapshot's, a 'WindowPhase', and each attribute as an 'Attribute': logical
-- extent, framebuffer extent, content scale, and desktop placement are
-- separate fields. A query that reports only @GLFW_FEATURE_UNAVAILABLE@ yields
-- 'Unavailable'; any other report fails the boundary with 'NativeFailure'.
-- Nothing observed is ever copied from the request. A zero framebuffer extent
-- is an ordinary observation of a window that cannot be drawn to.
--
-- = Lifecycle phases
--
-- An observation's 'WindowPhase' records where the window is in its lifetime:
--
-- * 'WindowOpen' from creation;
-- * 'WindowClosing' once an owner has begun the window's close protocol with the
--   private 'beginWindowClosing', published as its own revision in the same
--   transaction as the owner's own record that closing began, so no
--   cancellation can separate the two; reconciliation keeps the phase while
--   callbacks are still attached;
-- * exactly one terminal phase, published by release as the snapshot's last
--   revision before it closes: 'WindowReleased' when every release part
--   succeeded, 'WindowDisposalFailed' when a part failed but release stayed
--   certain, and 'WindowReleaseUncertain' when release could not establish that
--   callbacks and the native window ended safely.
--
-- The terminal phase is computed from two flags the release parts set, not from
-- the exceptions they raise: nothing is formatted, logged, or retained in the
-- observation, and the failures themselves stay on the release's failure path as
-- cleanup evidence. A lexically scoped window never passes through
-- 'WindowClosing'.
module Hetoimasia.GLFW.Internal.Window.Observation
  ( WindowPhase (..)
  , CloseRequest (..)
  , closeRequestWindow
  , closeRequestNumber
  , WindowObservation (..)
  , observedWindow
  , observedRevision
  , observedPhase
  , observedLogicalExtent
  , observedFramebufferExtent
  , observedContentScale
  , observedPlacement
  , observedFocused
  , observedIconified
  , observedMaximized
  , observedVisible
  , observedCloseRequest
  , observedDecorated
  , observedFullscreenMonitor
  , observedMode
  , observedCursorPosition
  , observedCursorInside
  ) where

import Control.DeepSeq (NFData (rnf))
import GHC.Generics (Generic)
import Hetoimasia.GLFW.Internal.Attribute (Attribute (..), ContentScale (..), CursorPosition (..), Extent (..), Placement (..))
import Hetoimasia.GLFW.Internal.Mode (ModeRecord)
import Hetoimasia.GLFW.Internal.Monitor (MonitorId)
import Hetoimasia.GLFW.Internal.Window.Identity (WindowId)
import Numeric.Natural (Natural)

-- | Where a window is in its lifetime.
data WindowPhase
  = WindowOpen
    -- ^ Created, live, and not yet closing.
  | WindowClosing
    -- ^ Its owner has begun its close protocol; it is not yet released.
  | WindowReleased
    -- ^ Disposed successfully: callbacks detached and the native window
    -- destroyed, with no release part failing.
  | WindowDisposalFailed
    -- ^ Disposal failed: a release part failed, but release still established
    -- that callbacks and the native window ended safely.
  | WindowReleaseUncertain
    -- ^ Disposal failed, and release could not establish that callbacks and the
    -- native window ended safely.
  deriving (Eq, Show, Generic)

instance NFData WindowPhase

-- | One native close request, numbered in increasing order per window.
data CloseRequest = CloseRequest !WindowId !Natural
  deriving (Eq, Ord, Show)

instance NFData CloseRequest where
  rnf (CloseRequest window number) = rnf window `seq` rnf number

-- | The window the request was made for.
closeRequestWindow ∷ CloseRequest → WindowId
closeRequestWindow (CloseRequest window _) = window

-- | The request's number: one more than the window's previous request.
closeRequestNumber ∷ CloseRequest → Natural
closeRequestNumber (CloseRequest _ number) = number

-- | One immutable observation of a window. Its representation is private, so
-- no observation is ever built outside this package.
data WindowObservation = WindowObservation
  { obsWindow ∷ !WindowId
  , obsRevision ∷ !Natural
  , obsPhase ∷ !WindowPhase
  , obsLogical ∷ !(Attribute Extent)
  , obsFramebuffer ∷ !(Attribute Extent)
  , obsScale ∷ !(Attribute ContentScale)
  , obsPlacement ∷ !(Attribute Placement)
  , obsFocused ∷ !(Attribute Bool)
  , obsIconified ∷ !(Attribute Bool)
  , obsMaximized ∷ !(Attribute Bool)
  , obsVisible ∷ !(Attribute Bool)
  , obsCloseRequest ∷ !(Maybe CloseRequest)
  , obsDecorated ∷ !(Attribute Bool)
  , obsMonitor ∷ !(Attribute (Maybe MonitorId))
  , obsMode ∷ !ModeRecord
  , obsCursor ∷ !(Maybe CursorPosition)
    -- ^ Latest cursor callback; 'Nothing' until one has run.
  , obsCursorInside ∷ !(Maybe Bool)
    -- ^ Latest enter/leave callback; 'Nothing' until one has run.
  }
  deriving (Eq, Show)

instance NFData WindowObservation where
  rnf observation =
    rnf (obsWindow observation)
      `seq` rnf (obsRevision observation)
      `seq` rnf (obsPhase observation)
      `seq` rnf (obsLogical observation)
      `seq` rnf (obsFramebuffer observation)
      `seq` rnf (obsScale observation)
      `seq` rnf (obsPlacement observation)
      `seq` rnf (obsFocused observation)
      `seq` rnf (obsIconified observation)
      `seq` rnf (obsMaximized observation)
      `seq` rnf (obsVisible observation)
      `seq` rnf (obsCloseRequest observation)
      `seq` rnf (obsDecorated observation)
      `seq` rnf (obsMonitor observation)
      `seq` rnf (obsMode observation)
      `seq` rnf (obsCursor observation)
      `seq` rnf (obsCursorInside observation)

-- | The window observed.
observedWindow ∷ WindowObservation → WindowId
observedWindow = obsWindow

-- | The observation's revision: zero for the initial observation, and the
-- snapshot's revision for every later one.
observedRevision ∷ WindowObservation → Natural
observedRevision = obsRevision

observedPhase ∷ WindowObservation → WindowPhase
observedPhase = obsPhase

-- | The content area's size in screen coordinates.
observedLogicalExtent ∷ WindowObservation → Attribute Extent
observedLogicalExtent = obsLogical

-- | The framebuffer's size in pixels. A zero extent is a valid observation of a
-- window that cannot currently be drawn to.
observedFramebufferExtent ∷ WindowObservation → Attribute Extent
observedFramebufferExtent = obsFramebuffer

observedContentScale ∷ WindowObservation → Attribute ContentScale
observedContentScale = obsScale

observedPlacement ∷ WindowObservation → Attribute Placement
observedPlacement = obsPlacement

observedFocused ∷ WindowObservation → Attribute Bool
observedFocused = obsFocused

observedIconified ∷ WindowObservation → Attribute Bool
observedIconified = obsIconified

observedMaximized ∷ WindowObservation → Attribute Bool
observedMaximized = obsMaximized

observedVisible ∷ WindowObservation → Attribute Bool
observedVisible = obsVisible

-- | The latest close request nobody has rejected, if any.
observedCloseRequest ∷ WindowObservation → Maybe CloseRequest
observedCloseRequest = obsCloseRequest

-- | The decoration GLFW holds for the window, which it applies whenever the
-- window is not on a monitor.
observedDecorated ∷ WindowObservation → Attribute Bool
observedDecorated = obsDecorated

-- | The monitor GLFW reports a fullscreen window on: 'Observed' 'Nothing' for a
-- window on no monitor, and 'Unavailable' for a monitor no current identity
-- names.
observedFullscreenMonitor ∷ WindowObservation → Attribute (Maybe MonitorId)
observedFullscreenMonitor = obsMonitor

-- | The owner's mode record as of this observation: the requested mode, the
-- applied mode reconciled from what was sampled, the saved windowed placement,
-- and the last outcome.
observedMode ∷ WindowObservation → ModeRecord
observedMode = obsMode

-- | The latest cursor position a cursor callback recorded, if any. Cursor
-- motion coalesces: an observation keeps only the last sample, never a trail.
observedCursorPosition ∷ WindowObservation → Maybe CursorPosition
observedCursorPosition = obsCursor

-- | Whether the cursor is inside the content area, as the latest enter or leave
-- callback reported it, if any has.
observedCursorInside ∷ WindowObservation → Maybe Bool
observedCursorInside = obsCursorInside
