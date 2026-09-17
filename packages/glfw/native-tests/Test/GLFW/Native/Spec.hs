-- | The native GLFW examples, composed under one GLFW group so
-- @--match "GLFW native"@ selects all of them.
--
-- The fixture harness examples prove the dispatcher's settlement rules, first
-- against a scripted owner and then against the real shared session; the
-- native opt-in examples prove the consent gate against a scripted owner and
-- a recorded launcher, and need no consent themselves; the
-- session, window, window control, window mode, monitor inventory, and window
-- host examples
-- use that shared session; the
-- private-session examples run lifecycles no shared session can host in a child
-- process. Every group that uses the session or starts a child runs under the
-- run's consent hook, so without consent each of its examples is refused
-- before its body.
module Test.GLFW.Native.Spec (spec) where

import qualified Test.GLFW.Native.Control as Control
import qualified Test.GLFW.Native.Guard as Guard
import qualified Test.GLFW.Native.Harness as Harness
import qualified Test.GLFW.Native.Mode as Mode
import qualified Test.GLFW.Native.Host as Host
import qualified Test.GLFW.Native.Input as Input
import qualified Test.GLFW.Native.Monitor as Monitor
import qualified Test.GLFW.Native.Private as Private
import qualified Test.GLFW.Native.Session as Session
import Test.GLFW.Native.Support (Shared (sharedGate), consented)
import qualified Test.GLFW.Native.Window as Window
import Test.Hspec (Spec, describe)

spec ∷ Shared → Spec
spec shared = describe "GLFW native" $ do
  Harness.spec shared
  Guard.spec
  consented (sharedGate shared) $ do
    Session.spec shared
    Window.spec shared
    Control.spec shared
    Mode.spec shared
    Monitor.spec shared
    Host.spec shared
    Input.spec shared
    Private.spec (sharedGate shared)
