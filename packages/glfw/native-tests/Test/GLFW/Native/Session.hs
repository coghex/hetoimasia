-- | The shared session: backend selection, native thread identity, sharing,
-- and the entry and ownership rules that hold while it is live.
module Test.GLFW.Native.Session (spec) where

import Control.Concurrent (forkIO, forkOS)
import Control.Monad (when)
import Hetoimasia.GLFW.Internal.Native (requestCloseForCheck, sizeLimitsForCheck)
import Hetoimasia.GLFW.Internal.Window (windowNativeHandle)
import Hetoimasia.GLFW.Session
  ( Backend (Wayland)
  , SessionMisuse (..)
  , defaultSessionConfig
  , reportedErrors
  , sessionBackend
  , takeAsynchronousReports
  , withSession
  )
import Hetoimasia.GLFW.Window (hiddenTestWindowConfig, withWindow)
import System.Environment (lookupEnv)
import System.Info (os)
import Test.GLFW.Native.Consent (Consent (IsolatedWayland), waylandValue)
import Test.GLFW.Native.Support
  ( Shared (..)
  , ThreadFacts (..)
  , acquisitions
  , expectFailure
  , gateConsent
  , hostBackend
  , onThread
  , owned
  , sharedBackend
  , threadFacts
  )
import Test.Hspec (Spec, describe, it, pendingWith, shouldBe, shouldReturn, shouldSatisfy)

spec ∷ Shared → Spec
spec shared = describe "the shared session" $ do
  it "selects the platform's own backend explicitly, on an isolated X11 display under Linux" $
    case gateConsent (sharedGate shared) of
      Right (IsolatedWayland socket) →
        pendingWith
          ( "this run is authorized for the isolated Wayland socket "
              <> socket
              <> "; the platform's own backend is what the X11 and Cocoa runs select"
          )
      _ → do
        owned shared (pure . sessionBackend) `shouldReturn` hostBackend
        when (os == "linux") $ do
          lookupEnv "DISPLAY" >>= (`shouldSatisfy` maybe False (not . null))
          lookupEnv "WAYLAND_DISPLAY" `shouldReturn` Nothing

  -- The Wayland-only assertions, in a group of their own so the catalog's
  -- test.glfw-wayland selector names exactly them. Each is listed on every
  -- platform, so a dry run names them and the catalog can select them
  -- anywhere, but each asserts only against a session the isolated
  -- compositor's consent authorized: an X11 or Cocoa run reaches the body and
  -- reports it pending rather than asserting Wayland against the session it
  -- actually has.
  describe "on an isolated Wayland session" $ do
    it "selects the Wayland backend it requested, on the isolated compositor's own socket" $
      onIsolatedWayland $ \socket → do
        owned shared (pure . sessionBackend) `shouldReturn` Wayland
        lookupEnv "WAYLAND_DISPLAY" `shouldReturn` Just socket
        lookupEnv "DISPLAY" `shouldReturn` Nothing

    -- Requirement 4's own check, on the backend it is about. Both drivers
    -- reach a window through a Cocoa or X11 handle, so on Wayland each must
    -- answer unavailable, and must do so without asking GLFW for a handle it
    -- would refuse: a GLFW_PLATFORM_UNAVAILABLE from glfwGetX11Display would
    -- be captured on the owner thread, and takeAsynchronousReports settles
    -- exactly those strays, so an empty report list is the evidence that
    -- neither driver touched X11 at all.
    it "answers both X11 test-check helpers unavailable, leaving no GLFW report" $
      onIsolatedWayland $ \_ → do
        (closed, limits, reports) ←
          owned shared $ \session →
            withWindow session (hiddenTestWindowConfig "wayland helper check" 200 150) $ \window → do
              let handle = windowNativeHandle window
              closed ← requestCloseForCheck handle
              limits ← sizeLimitsForCheck handle
              reports ← takeAsynchronousReports session
              pure (closed, limits, reports)
        closed `shouldBe` False
        limits `shouldBe` Nothing
        reportedErrors reports `shouldBe` []

  it "runs each dispatched operation on the bound process main thread that entered the session" $ do
    owned shared (\_ → threadFacts (sharedEvidence shared)) `shouldReturn` ThreadFacts True True True
    worker ← threadFacts (sharedEvidence shared)
    factProcessMainThread worker `shouldBe` False
    factOwnerThread worker `shouldBe` False

  it "is acquired once for every compatible example, whichever of them run" $ do
    _ ← owned shared (pure . sessionBackend)
    acquisitions shared `shouldReturn` 1

  it "rejects a nested entry on the owner thread and keeps serving" $ do
    owned shared (\_ → expectFailure (withSession defaultSessionConfig (\_ → pure ())))
      `shouldReturn` SessionAlreadyActive
    owned shared (pure . sessionBackend) `shouldReturn` sharedBackend (sharedGate shared)

  it "rejects entry from a bound worker thread" $
    onThread forkOS (expectFailure (withSession defaultSessionConfig (\_ → pure ())))
      `shouldReturn` NotProcessMainThread

  it "rejects entry from an unbound thread" $
    onThread forkIO (expectFailure (withSession defaultSessionConfig (\_ → pure ())))
      `shouldReturn` NotProcessMainThread

  it "rejects owner-only use of the shared session from the Hspec worker" $ do
    session ← owned shared pure
    expectFailure (takeAsynchronousReports session) `shouldReturn` NotSessionOwner
  where
    -- Run an assertion only on a session the isolated compositor authorized,
    -- naming the socket it named; anywhere else the example is pending, and
    -- says which command supplies that consent.
    onIsolatedWayland assert = case gateConsent (sharedGate shared) of
      Right (IsolatedWayland socket) → assert socket
      _ →
        pendingWith
          ( "this run carries no isolated Wayland consent; `bash tools/display/wayland.sh -- <command>` supplies "
              <> waylandValue "<socket>"
              <> " for one command"
          )
