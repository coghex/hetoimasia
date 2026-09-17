-- | The per-run authorization the native suite requires before it enters a
-- native session or starts a private-session child.
--
-- The native examples show, focus, resize, minimize, maximize, and take
-- fullscreen windows on whatever desktop they run on. The owner permits that
-- disruption, but only once an agent has described it, asked the human user
-- for explicit approval, and waited for acceptance. That conversation cannot
-- be proven by software, so this module is an operational guard: a run enters
-- a native session only when its environment carries one of two consents,
-- read once at startup.
--
-- * @HETOIMASIA_NATIVE_SESSION=desktop@ is the human's approval for this one
--   run on the local desktop. It is supplied on the approved command itself,
--   never in a shell profile or in a script an agent runs on its own.
-- * @HETOIMASIA_NATIVE_SESSION=isolated-x11:DISPLAY@ is what
--   @tools/display/x11.sh@ gives the command it runs once its private X11
--   display is up. It authorizes only that display: it must match @DISPLAY@,
--   and it never describes a Cocoa desktop.
--
-- A bare @DISPLAY@, a @CI@ variable, or any other value is not consent. A
-- refusal is a value here, so what the run does with it — refuse the
-- operation, count it, and report once — is decided and tested without an
-- environment or a session.
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
    -- ^ The human user approved this run on the local desktop.
  | IsolatedX11 String
    -- ^ The isolated display helper started this run on the named display.
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
  deriving (Eq, Show)

-- | The environment variable the suite reads.
consentVariable ∷ String
consentVariable = "HETOIMASIA_NATIVE_SESSION"

-- | The value the human user supplies for one approved desktop run.
desktopValue ∷ String
desktopValue = "desktop"

-- | The prefix of the value the isolated display helper supplies, followed by
-- the display it established.
isolatedPrefix ∷ String
isolatedPrefix = "isolated-x11:"

-- | The value the isolated display helper supplies for one display.
isolatedValue ∷ String → String
isolatedValue display = isolatedPrefix <> display

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

-- | One message naming what is missing, what the native examples would do to
-- the desktop, how a human approves a run, and the isolated alternative.
refusalMessage ∷ Refusal → String
refusalMessage refusal =
  "this run is not authorized to enter a native session: "
    <> refusalReason refusal
    <> ". The native examples show, focus, resize, minimize, maximize, and take fullscreen windows on the desktop they run on, so an agent describes that disruption, asks the human user for explicit approval, and waits for acceptance; the approved command then carries "
    <> consentVariable
    <> "="
    <> desktopValue
    <> " for that one run. On Linux, `bash tools/display/x11.sh -- <command>` runs the command on an isolated X11 display instead and needs no approval. DISPLAY and CI are not consent."
