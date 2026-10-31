-- | The per-run authorization the launcher's native suite requires before it enters a native session.
--
-- This suite shows, focuses and closes windows on the desktop it runs on, so it carries the guard the other native
-- suites do: no ambient command enters a native session. The owner's standing approval (AGENTS.md, 2026-09-26)
-- covers such a run whenever an issue or pull request needs it; this is the operational guard, read once before
-- anything native happens:
--
-- * @HETOIMASIA_NATIVE_SESSION=desktop@ is the opt-in for one run on the local desktop, on the run's own command.
-- * @HETOIMASIA_NATIVE_SESSION=isolated-x11:DISPLAY@ is what @tools/display/x11.sh@ gives the command it runs once
--   its private X11 display is up, and authorizes only that display, on Linux, where @DISPLAY@ must name it.
-- * @HETOIMASIA_NATIVE_SESSION=isolated-wayland:SOCKET@ is what @tools/display/wayland.sh@ gives its command: only
--   that socket, on Linux, with @WAYLAND_DISPLAY@ naming it and @DISPLAY@ unset.
--
-- A bare @DISPLAY@ or @WAYLAND_DISPLAY@, or a @CI@ variable, is not consent. /The production @run@ command reads none of
-- this/: consent gates native test suites, never the user's command, and the command this suite launches is given
-- the environment as it is.
--
-- The rules match the other native suites' deliberately and live here rather than in a shared module because
-- AGENTS.md forbids importing a helper from another component's spec.
module Test.Run.Native.Consent
  ( Consent (..)
  , Refusal (..)
  , consentFrom
  , readConsent
  , describeConsent
  , refusalMessage
  ) where

import Data.List (stripPrefix)
import Data.Text (Text)
import qualified Data.Text as Text
import System.Environment (getEnvironment)
import System.Info (os)

-- | The authorization a run carries.
data Consent
  = Desktop
  | IsolatedX11 String
  | IsolatedWayland String
  deriving (Eq, Show)

-- | Why a run carries none.
data Refusal
  = NoConsent
  | UnknownConsent String
  | IsolationElsewhere String (Maybe String)
  | IsolationOffPlatform String String
  | WaylandIsolationElsewhere String (Maybe String)
  | WaylandIsolationBesideX11 String String
  | WaylandIsolationOffPlatform String String
  deriving (Eq, Show)

consentVariable ∷ String
consentVariable = "HETOIMASIA_NATIVE_SESSION"

-- | The consent an environment carries on a platform, or why it carries none.
consentFrom ∷ String → [(String, String)] → Either Refusal Consent
consentFrom platform environment =
  case lookup consentVariable environment of
    Nothing → Left NoConsent
    Just "" → Left NoConsent
    Just "desktop" → Right Desktop
    Just value
      | Just display ← stripPrefix "isolated-x11:" value →
          if platform /= "linux"
            then Left (IsolationOffPlatform display platform)
            else
              let current = lookup "DISPLAY" environment
               in if null display || current /= Just display then Left (IsolationElsewhere display current) else Right (IsolatedX11 display)
      | Just socket ← stripPrefix "isolated-wayland:" value →
          if platform /= "linux"
            then Left (WaylandIsolationOffPlatform socket platform)
            else
              let current = lookup "WAYLAND_DISPLAY" environment
               in if null socket || current /= Just socket
                    then Left (WaylandIsolationElsewhere socket current)
                    else maybe (Right (IsolatedWayland socket)) (Left . WaylandIsolationBesideX11 socket) (lookup "DISPLAY" environment)
      | otherwise → Left (UnknownConsent value)

readConsent ∷ IO (Either Refusal Consent)
readConsent = consentFrom os <$> getEnvironment

describeConsent ∷ Consent → Text
describeConsent = \case
  Desktop → "the desktop opt-in on this run's command, under the owner's standing approval"
  IsolatedX11 display → "the isolated X11 display " <> Text.pack display
  IsolatedWayland socket → "the isolated Wayland socket " <> Text.pack socket

refusalMessage ∷ Refusal → Text
refusalMessage refusal =
  "this run is not authorized to enter a native session: "
    <> reason
    <> ". The launcher's native suite shows and closes windows on the desktop it runs on, so only a command that asks for the desktop carries "
    <> Text.pack consentVariable
    <> "=desktop for that one run; the owner's standing approval covers runs an issue or pull request needs (AGENTS.md), and periodic testing asks the owner first. On Linux, `bash tools/vulkan/run.sh native hetoimasia:test:run-native-tests` runs the suite on an isolated X11 display it starts, which needs no approval. DISPLAY, WAYLAND_DISPLAY and CI are not consent."
  where
    reason = case refusal of
      NoConsent → Text.pack consentVariable <> " is not set"
      UnknownConsent value → Text.pack consentVariable <> "=" <> Text.pack (show value) <> " is not a consent this suite recognizes"
      IsolationElsewhere display current → Text.pack consentVariable <> " authorizes the isolated X11 display " <> Text.pack (show display) <> " but DISPLAY is " <> maybe "not set" (Text.pack . show) current
      IsolationOffPlatform display platform → Text.pack consentVariable <> " authorizes the isolated X11 display " <> Text.pack (show display) <> ", which is not a session on " <> Text.pack platform
      WaylandIsolationElsewhere socket current → Text.pack consentVariable <> " authorizes the isolated Wayland socket " <> Text.pack (show socket) <> " but WAYLAND_DISPLAY is " <> maybe "not set" (Text.pack . show) current
      WaylandIsolationBesideX11 socket display → Text.pack consentVariable <> " authorizes the isolated Wayland socket " <> Text.pack (show socket) <> " but DISPLAY is " <> Text.pack (show display) <> ", which could serve an X11 or XWayland session instead"
      WaylandIsolationOffPlatform socket platform → Text.pack consentVariable <> " authorizes the isolated Wayland socket " <> Text.pack (show socket) <> ", which is not a session on " <> Text.pack platform
