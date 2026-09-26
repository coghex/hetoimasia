-- | The per-run authorization the Vulkan native suite requires before it
-- initializes GLFW, creates a window, touches a driver, or starts a child.
--
-- The suite opens windows and presents to them, so it disrupts whatever
-- desktop it runs on exactly as @glfw-native-tests@ does. The owner's standing
-- approval (AGENTS.md, 2026-09-26) covers such a session whenever an issue or
-- pull request needs it; this is the operational guard that keeps every other
-- command from opening windows, read once before anything native happens:
--
-- * @HETOIMASIA_NATIVE_SESSION=desktop@ is the opt-in for one run on the local
--   desktop, supplied on the run's own command.
-- * @HETOIMASIA_NATIVE_SESSION=isolated-x11:DISPLAY@ is what
--   @tools/display/x11.sh@ gives the command it runs once its private X11
--   display is up, and authorizes only that display.
--
-- A bare @DISPLAY@ or a @CI@ variable is not consent. The rules match
-- @Test.GLFW.Native.Consent@ deliberately, except that this suite has no
-- Wayland session: a run authorized for the GLFW suite's X11 or desktop session
-- is authorized for this one. It is a separate module rather than a shared one
-- because AGENTS.md forbids importing a helper from another component's spec.
module Test.GPU.Vulkan.Native.Consent
  ( Consent (..)
  , Refusal (..)
  , consentFrom
  , readConsent
  , consentVariable
  , describeConsent
  , refusalReason
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
  deriving (Eq, Show)

-- | Why a run carries none.
data Refusal
  = NoConsent
  | UnknownConsent String
  | IsolationElsewhere String (Maybe String)
  | IsolationOffPlatform String String
  deriving (Eq, Show)

consentVariable ∷ String
consentVariable = "HETOIMASIA_NATIVE_SESSION"

desktopValue ∷ String
desktopValue = "desktop"

isolatedPrefix ∷ String
isolatedPrefix = "isolated-x11:"

-- | The consent an environment carries on a platform, or why it carries none.
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
      | otherwise → Left (UnknownConsent value)

readConsent ∷ IO (Either Refusal Consent)
readConsent = consentFrom os <$> getEnvironment

describeConsent ∷ Consent → Text
describeConsent = \case
  Desktop → "the desktop opt-in on this run's command, under the owner's standing approval"
  IsolatedX11 display → "the isolated X11 display " <> Text.pack display

refusalReason ∷ Refusal → Text
refusalReason = \case
  NoConsent → Text.pack consentVariable <> " is not set"
  UnknownConsent value →
    Text.pack consentVariable <> "=" <> Text.pack (show value) <> " is not a consent this suite recognizes"
  IsolationElsewhere display current →
    Text.pack consentVariable
      <> " authorizes the isolated X11 display "
      <> Text.pack (show display)
      <> " but DISPLAY is "
      <> maybe "not set" (Text.pack . show) current
  IsolationOffPlatform display platform →
    Text.pack consentVariable
      <> " authorizes the isolated X11 display "
      <> Text.pack (show display)
      <> ", which is not a session on "
      <> Text.pack platform

-- | One message naming what is missing, what the suite would do to the desktop,
-- how a run opts in, and the isolated alternative.
refusalMessage ∷ Refusal → Text
refusalMessage refusal =
  "this run is not authorized to enter a native session: "
    <> refusalReason refusal
    <> ". The Vulkan native suite opens windows on the desktop it runs on and presents to them, so only a command that asks for the desktop carries "
    <> Text.pack consentVariable
    <> "="
    <> Text.pack desktopValue
    <> " for that one run; the owner's standing approval covers runs an issue or pull request needs (AGENTS.md), and periodic testing asks the owner first. On Linux, `bash tools/vulkan/run.sh native <component>` runs the suite on an isolated X11 display it starts instead, and needs no approval. DISPLAY and CI are not consent."
