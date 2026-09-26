-- | The shared session: backend selection, native thread identity, sharing,
-- and the entry and ownership rules that hold while it is live.
module Test.GLFW.Native.Session (spec) where

import Control.Concurrent (forkIO, forkOS)
import Control.Monad (when)
import Hetoimasia.GLFW.Session
  ( SessionMisuse (..)
  , defaultSessionConfig
  , sessionBackend
  , takeAsynchronousReports
  , withSession
  )
import System.Environment (lookupEnv)
import System.Info (os)
import Test.GLFW.Native.Consent (Consent (IsolatedWayland))
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
