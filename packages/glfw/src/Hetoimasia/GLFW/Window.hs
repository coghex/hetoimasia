-- | Scoped GLFW windows and the observations they publish.
--
-- 'allocWindow' creates a NoAPI window in a live 'Session' for the rest of the
-- enclosing 'Hetoimasia.Foundation.Resource.withScoped' scope, and 'withWindow'
-- is that scope on its own. Any number of windows may be live at once; nothing
-- here assumes a single or primary window.
--
-- A window publishes one immutable 'WindowObservation' at a time through a
-- latest-value snapshot, read with 'windowObservations' and the operations of
-- "Hetoimasia.Foundation.Messaging.Snapshot". Every attribute is what the
-- platform reported, or explicitly 'Unavailable'; nothing is copied from the
-- request. A native close request appears as 'observedCloseRequest' and never
-- destroys the window: what it means is the application's decision.
--
-- Callbacks only record. Their captures are reconciled on the owner thread at
-- an owner boundary — creation, and 'synchronizeWindow' — and a fault raised
-- inside a callback is rethrown there. When the scope ends, callbacks are
-- detached, the native window is destroyed, and the snapshot is closed holding
-- the terminal observation. The handle is then terminal: 'synchronizeWindow'
-- answers 'WindowEnded' without a native call, and the session can create
-- another window.
--
-- See "Hetoimasia.GLFW.Internal.Window"'s contract, repeated in prose in
-- @docs/glfw.md@, for the owner, thread, lifetime, observation, callback
-- containment, and release-order rules.
--
-- @
-- withSession defaultSessionConfig $ \\session →
--   withWindow session (hiddenTestWindowConfig "tool" 640 480) $ \\window → do
--     initial ← atomically (readSnapshot (windowObservations window))
--     print (observedFramebufferExtent (preparedValue (observedValue initial)))
-- @
module Hetoimasia.GLFW.Window
  ( -- * Windows
    Window
  , allocWindow
  , withWindow
  , windowIdentity
  , windowObservations
  , windowEnded
  , synchronizeWindow
  , WindowResult (..)

    -- * Configuration
  , WindowConfig (..)
  , defaultWindowConfig
  , hiddenTestWindowConfig
  , validateWindowConfig
  , WindowConfigRejected (..)

    -- * Identity
  , WindowId
  , windowLocalIdentity

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
  , WindowPhase (..)
  , Attribute (..)
  , Extent (..)
  , ContentScale (..)
  , Placement (..)
  , CloseRequest
  , closeRequestWindow
  , closeRequestNumber
  ) where

import Hetoimasia.Foundation.Resource (Scoped, allocComposite, withScoped)
import Hetoimasia.GLFW.Internal.Session (Session)
import Hetoimasia.GLFW.Internal.Window
  ( Attribute (..)
  , CloseRequest
  , ContentScale (..)
  , Extent (..)
  , Placement (..)
  , Window
  , WindowConfig (..)
  , WindowConfigRejected (..)
  , WindowId
  , WindowObservation
  , WindowPhase (..)
  , WindowResult (..)
  , closeRequestNumber
  , closeRequestWindow
  , defaultWindowConfig
  , hiddenTestWindowConfig
  , observedCloseRequest
  , observedContentScale
  , observedFocused
  , observedFramebufferExtent
  , observedIconified
  , observedLogicalExtent
  , observedMaximized
  , observedPhase
  , observedPlacement
  , observedRevision
  , observedVisible
  , observedWindow
  , synchronizeWindow
  , validateWindowConfig
  , windowAssembly
  , windowEnded
  , windowIdentity
  , windowLocalIdentity
  , windowObservations
  )

-- | Create a window in the session for the rest of the enclosing scope.
--
-- The configuration is validated before any native call. A failure at any
-- stage of creation releases exactly what was acquired before it and
-- propagates with its evidence.
allocWindow ∷ Session → WindowConfig → Scoped Window
allocWindow session = allocComposite . windowAssembly session

-- | Create a window, lend it to the body, and release it.
withWindow ∷ Session → WindowConfig → (Window → IO r) → IO r
withWindow session config = withScoped (allocWindow session config)
