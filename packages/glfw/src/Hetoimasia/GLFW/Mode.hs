-- | Window modes: windowed, borderless over a selected monitor's work area, and
-- fullscreen on a selected monitor.
--
-- A 'ModeRequest' pairs a 'WindowMode' with a 'ModeFallback', and
-- "Hetoimasia.GLFW.Command"'s 'Hetoimasia.GLFW.Command.setWindowModeCommand'
-- submits it; a 'Hetoimasia.GLFW.Window.WindowConfig' may carry a
-- 'StartupMode' instead. Requests are validated on the owner thread when they
-- execute, against the window and the monitors GLFW reports then: the monitor is
-- re-resolved, the video mode must be one the monitor reports, a fullscreen
-- monitor another window claims is 'MonitorBusy', and nothing reaches a native
-- setter until every check has passed.
--
-- A window's observation carries its 'ModeRecord': the requested mode, the
-- 'AppliedMode' reconciled from what the platform reported, the saved windowed
-- placement, and the last 'ModeOutcome'. None of these types exports a
-- constructor a client could use to set a placement or skip validation.
--
-- See "Hetoimasia.GLFW.Internal.Mode"'s contract, repeated in prose in
-- @docs/glfw.md@, for the placement cache, fallback, claim, and eligibility
-- rules.
--
-- @
-- goFullscreen ∷ WindowCommandPort → WindowId → MonitorId → IO SubmitResult
-- goFullscreen port window monitor =
--   submitWindowCommand port [] . setWindowModeCommand window $
--     modeRequest (fullscreenMode monitor currentVideoMode) (windowedFallback 1)
-- @
module Hetoimasia.GLFW.Mode
  ( -- * Requests
    WindowMode
  , windowedMode
  , borderlessMode
  , fullscreenMode
  , modePresentation
  , modeMonitor
  , modeVideoPreference
  , PresentationKind (..)
  , VideoModePreference
  , currentVideoMode
  , exactVideoMode
  , preferredVideoMode
  , ModeFallback
  , noModeFallback
  , windowedFallback
  , fallbackAttempts
  , maximumFallbackAttempts
  , ModeRequest
  , modeRequest
  , requestedMode
  , requestedFallback
  , ModeRequirement (..)
  , StartupMode
  , startupMode
  , startupRequest
  , startupRequirement

    -- * The mode record
  , ModeRecord
  , modeRequested
  , modeFallback
  , modeApplied
  , modeSavedPlacement
  , modeLastOutcome
  , AppliedMode (..)
  , SavedPlacement
  , savedPosition
  , savedExtent

    -- * Outcomes
  , ModeRejection (..)
  , ModeStep (..)
  , ModeAttemptKind (..)
  , ModeFailure (..)
  , ModeAttemptFailure (..)
  , ModeOutcome (..)
  ) where

import Hetoimasia.GLFW.Internal.Control (PresentationKind (..))
import Hetoimasia.GLFW.Internal.Mode
  ( AppliedMode (..)
  , ModeAttemptFailure (..)
  , ModeAttemptKind (..)
  , ModeFailure (..)
  , ModeFallback
  , ModeOutcome (..)
  , ModeRecord
  , ModeRejection (..)
  , ModeRequest
  , ModeRequirement (..)
  , ModeStep (..)
  , SavedPlacement
  , StartupMode
  , VideoModePreference
  , WindowMode
  , borderlessMode
  , currentVideoMode
  , exactVideoMode
  , fallbackAttempts
  , fullscreenMode
  , maximumFallbackAttempts
  , modeApplied
  , modeFallback
  , modeLastOutcome
  , modeMonitor
  , modePresentation
  , modeRequest
  , modeRequested
  , modeSavedPlacement
  , modeVideoPreference
  , noModeFallback
  , preferredVideoMode
  , requestedFallback
  , requestedMode
  , savedExtent
  , savedPosition
  , startupMode
  , startupRequest
  , startupRequirement
  , windowedFallback
  , windowedMode
  )
