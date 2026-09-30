-- | Scoped GLFW windows and the observations they publish, written over the
-- session's table of native operations.
--
-- A 'Window' is created inside a live 'Session' by 'windowAssembly', one staged
-- composite that acquires the window's callback storage, its native window,
-- the callbacks' registration, and the snapshot its observations are published
-- through. It is lent to the enclosing scope and released when that scope ends.
-- Collection-backed construction — the window host's dynamic windows in
-- "Hetoimasia.Runtime.GLFW" — reuses the same assembly as one member of a
-- "Hetoimasia.Foundation.Resource.Collection"; there is no second acquisition or
-- cleanup path.
--
-- = Owner, thread, and lifetime
--
-- The owner is the session's owner, the process main thread. Every native call
-- and every owner boundary below runs there, and each checks, before any native
-- call, that it does ('NotSessionOwner') and that the session is live
-- ('SessionEnded'). A window lives until its enclosing scope ends. Its handle
-- turns terminal as the first step of release, after every borrowing scope has
-- ended, and every later operation through it answers 'WindowEnded' without a
-- native call. Identities are the session's identity and a local number the
-- session never reissues, so a later window never answers to an ended one's
-- handle.
--
-- = Where each part lives
--
-- This module is the composition its importers use; it defines nothing. Every
-- part is a private module beneath it, with its own thread and state owner
-- named in its header:
--
-- * "Hetoimasia.GLFW.Internal.Window.Identity",
--   "Hetoimasia.GLFW.Internal.Window.Config" and
--   "Hetoimasia.GLFW.Internal.Window.Observation": a window's identity, its
--   configuration, and the observations and lifecycle phases it publishes.
--   Values only. The input feed names a window through the identity leaf, so
--   no module imports the window model to do so.
-- * "Hetoimasia.GLFW.Internal.Window.State": the one window handle, the
--   records its cells hold, and the state table.
-- * "Hetoimasia.GLFW.Internal.Window.Sample" and
--   "Hetoimasia.GLFW.Internal.Window.Callbacks": sampling attributes, and the
--   contained callbacks that fill the capture latch.
-- * "Hetoimasia.GLFW.Internal.Window.Reconcile" and
--   "Hetoimasia.GLFW.Internal.Window.Boundary": the reconciliation protocol,
--   and the owner boundaries, drivers, close requests, and event pump built on
--   it.
-- * "Hetoimasia.GLFW.Internal.Window.Controls",
--   "Hetoimasia.GLFW.Internal.Window.ModeAttempt" and
--   "Hetoimasia.GLFW.Internal.Window.ModeTransition": ordinary controls and
--   mode transitions, the native interpreters of the pure
--   "Hetoimasia.GLFW.Internal.Control" rules and
--   "Hetoimasia.GLFW.Internal.Mode" planner.
-- * "Hetoimasia.GLFW.Internal.Window.Construction": the staged assembly and
--   release.
module Hetoimasia.GLFW.Internal.Window
  ( -- * Configuration
    WindowConfig (..)
  , defaultWindowConfig
  , hiddenTestWindowConfig
  , WindowConfigRejected (..)
  , validateWindowConfig

    -- * Windows
  , Window
  , windowAssembly
  , windowIdentity
  , windowObservations
  , windowEnded
  , WindowResult (..)
  , synchronizeWindow

    -- * Identity
  , WindowId
  , windowLocalIdentity
  , windowSessionIdentity

    -- * Observations
  , WindowObservation
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
  , WindowPhase (..)
  , Attribute (..)
  , Extent (..)
  , ContentScale (..)
  , Placement (..)
  , CursorPosition (..)
  , CloseRequest
  , closeRequestWindow
  , closeRequestNumber

    -- * Ordinary controls
  , controlWindow
  , setModeTransition

    -- * Window modes
  , transitionWindow
  , transitionWindowWith
  , reconcileWindowMode

    -- * Private owner-turn operations
  , EventProcessing (..)
  , processWindowEvents
  , reconcileWindowEvents

    -- * Private owner-boundary drivers
  , windowStep
  , windowStepWith
  , windowSession
  , rejectCloseRequest
  , beginWindowClosing
  , windowNativeHandle
  , windowCallbackOperation
  , attachWindowInputFeed
  , windowInputFeed
  , inputStagingCapacity
  ) where

import Hetoimasia.GLFW.Internal.Attribute (Attribute (..), ContentScale (..), CursorPosition (..), Extent (..), Placement (..))
import Hetoimasia.GLFW.Internal.Window.Boundary
  ( EventProcessing (..)
  , beginWindowClosing
  , processWindowEvents
  , reconcileWindowEvents
  , rejectCloseRequest
  , synchronizeWindow
  , windowStep
  , windowStepWith
  )
import Hetoimasia.GLFW.Internal.Window.Config
  ( WindowConfig (..)
  , WindowConfigRejected (..)
  , defaultWindowConfig
  , hiddenTestWindowConfig
  , validateWindowConfig
  )
import Hetoimasia.GLFW.Internal.Window.Construction (windowAssembly)
import Hetoimasia.GLFW.Internal.Window.Controls (controlWindow)
import Hetoimasia.GLFW.Internal.Window.Identity (WindowId, windowLocalIdentity, windowSessionIdentity)
import Hetoimasia.GLFW.Internal.Window.ModeTransition (reconcileWindowMode, transitionWindow, transitionWindowWith)
import Hetoimasia.GLFW.Internal.Window.Observation
  ( CloseRequest
  , WindowObservation
  , WindowPhase (..)
  , closeRequestNumber
  , closeRequestWindow
  , observedCloseRequest
  , observedContentScale
  , observedCursorInside
  , observedCursorPosition
  , observedDecorated
  , observedFocused
  , observedFramebufferExtent
  , observedFullscreenMonitor
  , observedIconified
  , observedLogicalExtent
  , observedMaximized
  , observedMode
  , observedPhase
  , observedPlacement
  , observedRevision
  , observedVisible
  , observedWindow
  )
import Hetoimasia.GLFW.Internal.Window.State
  ( Window
  , WindowResult (..)
  , attachWindowInputFeed
  , inputStagingCapacity
  , setModeTransition
  , windowCallbackOperation
  , windowEnded
  , windowIdentity
  , windowInputFeed
  , windowNativeHandle
  , windowObservations
  , windowSession
  )
