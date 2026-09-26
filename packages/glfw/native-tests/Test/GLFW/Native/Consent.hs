-- | The per-run authorization the native suite requires before it enters a
-- native session or starts a private-session child.
--
-- The native examples show, focus, resize, minimize, maximize, and take
-- fullscreen windows on whatever desktop they run on. The owner gave standing
-- approval on 2026-09-26 for that disruption on the owner's machine whenever an
-- issue or pull request needs a native run (AGENTS.md). This module is the
-- operational guard that keeps every other command from opening windows: a run
-- enters a native session only when its environment carries one of these
-- consents, read once at startup.
--
-- * @HETOIMASIA_NATIVE_SESSION=desktop@ is the opt-in for this one run on the
--   local desktop. It is supplied on the run's own command, never in a shell
--   profile, a persistent environment, or a script that runs on its own.
-- * @HETOIMASIA_NATIVE_SESSION=isolated-x11:DISPLAY@ is what
--   @tools/display/x11.sh@ gives the command it runs once its private X11
--   display is up. It authorizes only that display: it must match @DISPLAY@,
--   and it never describes a Cocoa desktop.
-- * @HETOIMASIA_NATIVE_SESSION=isolated-wayland:SOCKET@ is what
--   @tools/display/wayland.sh@ gives the command it runs once its private
--   compositor is serving. It authorizes only that socket: @WAYLAND_DISPLAY@
--   must name it and @DISPLAY@ must be unset, so no XWayland display can stand
--   in for the compositor, and it never describes a Cocoa desktop either.
--
-- A bare @DISPLAY@ or @WAYLAND_DISPLAY@, a @CI@ variable, or any other value is
-- not consent. A refusal is a value here, so what the run does with it —
-- refuse the operation, count it, and report once — is decided and tested
-- without an environment or a session.
module Test.GLFW.Native.Consent
  ( -- * Consent
    Consent (..)
  , Refusal (..)
  , consentFrom
  , readConsent

    -- * The variable
  , consentVariable
  , desktopValue
  , isolatedPrefix
  , isolatedValue
  , waylandPrefix
  , waylandValue

    -- * Refusing
  , NativeSessionRefused (..)
  , refusalReason
  , refusalMessage
  ) where

import Control.Exception (Exception (displayException))
import Data.List (stripPrefix)
import System.Environment (getEnvironment)
import System.Info (os)

-- | The authorization a run carries.
data Consent
  = Desktop
    -- ^ This run opted in to the local desktop.
  | IsolatedX11 String
    -- ^ The isolated display helper started this run on the named display.
  | IsolatedWayland String
    -- ^ The isolated compositor helper started this run on the named socket.
  deriving (Eq, Show)

-- | Why a run carries no authorization.
data Refusal
  = NoConsent
    -- ^ The variable is unset or empty.
  | UnknownConsent String
    -- ^ The variable holds a value that is neither consent.
  | IsolationElsewhere String (Maybe String)
    -- ^ The isolated authorization names one display while @DISPLAY@ names
    -- another, or none.
  | IsolationOffPlatform String String
    -- ^ The isolated authorization was given on a platform without X11.
  | WaylandIsolationElsewhere String (Maybe String)
    -- ^ The isolated Wayland authorization names one socket while
    -- @WAYLAND_DISPLAY@ names another, or none.
  | WaylandIsolationBesideX11 String String
    -- ^ The isolated Wayland authorization was given with @DISPLAY@ set, so an
    -- X11 or XWayland display could stand in for the compositor.
  | WaylandIsolationOffPlatform String String
    -- ^ The isolated Wayland authorization was given on a platform without
    -- Wayland.
  deriving (Eq, Show)

-- | The environment variable the suite reads.
consentVariable ∷ String
consentVariable = "HETOIMASIA_NATIVE_SESSION"

-- | The value a run's own command supplies to opt in to the local desktop.
desktopValue ∷ String
desktopValue = "desktop"

-- | The prefix of the value the isolated display helper supplies, followed by
-- the display it established.
isolatedPrefix ∷ String
isolatedPrefix = "isolated-x11:"

-- | The value the isolated display helper supplies for one display.
isolatedValue ∷ String → String
isolatedValue display = isolatedPrefix <> display

-- | The prefix of the value the isolated compositor helper supplies, followed
-- by the socket it established.
waylandPrefix ∷ String
waylandPrefix = "isolated-wayland:"

-- | The value the isolated compositor helper supplies for one socket.
waylandValue ∷ String → String
waylandValue socket = waylandPrefix <> socket

-- | The consent an environment carries on a platform, or why it carries none.
--
-- The platform is the operating system name as 'System.Info.os' reports it.
consentFrom ∷ String → [(String, String)] → Either Refusal Consent
consentFrom platform environment =
  case lookup consentVariable environment of
    Nothing → Left NoConsent
    Just "" → Left NoConsent
    Just value
      | value == desktopValue → Right Desktop
      | Just display ← stripPrefix isolatedPrefix value →
          if platform /= "linux"
            then Left (IsolationOffPlatform display platform)
            else
              let current = lookup "DISPLAY" environment
               in if null display || current /= Just display
                    then Left (IsolationElsewhere display current)
                    else Right (IsolatedX11 display)
      -- The Wayland authorization answers to WAYLAND_DISPLAY the way the X11
      -- one answers to DISPLAY, and additionally requires DISPLAY to be
      -- absent: a set DISPLAY, empty or not, would let an X11 or XWayland
      -- display stand in for the compositor the helper started.
      | Just socket ← stripPrefix waylandPrefix value →
          if platform /= "linux"
            then Left (WaylandIsolationOffPlatform socket platform)
            else
              let current = lookup "WAYLAND_DISPLAY" environment
                  display = lookup "DISPLAY" environment
               in if null socket || current /= Just socket
                    then Left (WaylandIsolationElsewhere socket current)
                    else maybe (Right (IsolatedWayland socket)) (Left . WaylandIsolationBesideX11 socket) display
      | otherwise → Left (UnknownConsent value)

-- | The consent this process's environment carries on this platform.
readConsent ∷ IO (Either Refusal Consent)
readConsent = consentFrom os <$> getEnvironment

-- | A native example, operation, or child launch was refused because the run
-- carries no consent. Raised on the thread that asked, before anything runs
-- or is dispatched. Its display is short — each refused example shows it —
-- and points at the run's closing line, which carries 'refusalMessage'.
newtype NativeSessionRefused = NativeSessionRefused Refusal
  deriving (Eq, Show)

instance Exception NativeSessionRefused where
  displayException (NativeSessionRefused refusal) =
    "refused without consent to enter a native session: " <> refusalReason refusal <> "; the run's last line says how to authorize one"

-- | What is missing, in one clause.
refusalReason ∷ Refusal → String
refusalReason = \case
  NoConsent → consentVariable <> " is not set"
  UnknownConsent value → consentVariable <> "=" <> show value <> " is not a consent this suite recognizes"
  IsolationElsewhere display current →
    consentVariable
      <> " authorizes the isolated X11 display "
      <> show display
      <> " but DISPLAY is "
      <> maybe "not set" show current
  IsolationOffPlatform display platform →
    consentVariable
      <> " authorizes the isolated X11 display "
      <> show display
      <> ", which is not a session on "
      <> platform
  WaylandIsolationElsewhere socket current →
    consentVariable
      <> " authorizes the isolated Wayland socket "
      <> show socket
      <> " but WAYLAND_DISPLAY is "
      <> maybe "not set" show current
  WaylandIsolationBesideX11 socket display →
    consentVariable
      <> " authorizes the isolated Wayland socket "
      <> show socket
      <> " but DISPLAY is "
      <> show display
      <> ", which could serve an X11 or XWayland session instead"
  WaylandIsolationOffPlatform socket platform →
    consentVariable
      <> " authorizes the isolated Wayland socket "
      <> show socket
      <> ", which is not a session on "
      <> platform

-- | One message naming what is missing, what the native examples would do to
-- the desktop, how a run opts in, and the isolated alternative.
refusalMessage ∷ Refusal → String
refusalMessage refusal =
  "this run is not authorized to enter a native session: "
    <> refusalReason refusal
    <> ". The native examples show, focus, resize, minimize, maximize, and take fullscreen windows on the desktop they run on, so only a command that asks for the desktop carries "
    <> consentVariable
    <> "="
    <> desktopValue
    <> " for that one run; the owner's standing approval covers runs an issue or pull request needs (AGENTS.md), and periodic testing asks the owner first. On Linux, `bash tools/display/x11.sh -- <command>` runs the command on an isolated X11 display instead, and `bash tools/display/wayland.sh -- <command>` on an isolated Wayland socket; neither needs approval. DISPLAY, WAYLAND_DISPLAY, and CI are not consent."
