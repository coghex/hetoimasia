-- | The native GLFW examples, composed under one GLFW group so
-- @--match "GLFW native"@ selects all of them.
--
-- The fixture harness examples prove the dispatcher's settlement rules, first
-- against a scripted owner and then against the real shared session; the
-- session and window examples use that shared session; the private-session
-- examples run lifecycles no shared session can host in a child process.
module Test.GLFW.Native.Spec (spec) where

import qualified Test.GLFW.Native.Harness as Harness
import qualified Test.GLFW.Native.Private as Private
import qualified Test.GLFW.Native.Session as Session
import Test.GLFW.Native.Support (Shared)
import qualified Test.GLFW.Native.Window as Window
import Test.Hspec (Spec, describe)

spec ∷ Shared → Spec
spec shared = describe "GLFW native" $ do
  Harness.spec shared
  Session.spec shared
  Window.spec shared
  Private.spec
