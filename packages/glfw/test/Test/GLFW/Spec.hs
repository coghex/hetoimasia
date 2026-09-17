-- | The GLFW package's headless suite, composed from its component specs.
--
-- None of them initializes GLFW, opens a window, or needs a display. The
-- session examples in "Test.GLFW.Session" drive the production session model
-- through the test seam; the window model, window command, window control,
-- window host, dynamic window, monitor inventory, input feed, and window mode
-- examples use the seam's private drivers, the private command executor, and the
-- runtime integration's private host hooks, which this suite may name because it
-- belongs to the package; "Test.GLFW.Linking" checks the package's link
-- declarations against the native manifest; and "Test.GLFW.Opacity" compiles
-- external clients against the package, which is the only evidence here of what
-- a client outside the package can reach.
--
-- All sit under the @GLFW@ group this module roots, so the paths and @--match@
-- selectors they carried in the root suite and in the package's former window
-- examples executable still select them here. A new headless
-- example belongs in the component that owns the behaviour it asserts; an
-- example that needs a real native session belongs in @glfw-native-tests@. This
-- module only composes.
module Test.GLFW.Spec (spec) where

import qualified Test.GLFW.Command as Command
import qualified Test.GLFW.Control as Control
import qualified Test.GLFW.Dynamic as Dynamic
import qualified Test.GLFW.Host as Host
import qualified Test.GLFW.Input as Input
import qualified Test.GLFW.Linking as Linking
import qualified Test.GLFW.Mode as Mode
import qualified Test.GLFW.Monitor as Monitor
import qualified Test.GLFW.Opacity as Opacity
import qualified Test.GLFW.Session as Session
import qualified Test.GLFW.Window as Window
import Test.Hspec (Spec, describe)

spec ∷ Spec
spec = describe "GLFW" $ do
  Session.spec
  Window.spec
  Command.spec
  Control.spec
  Host.spec
  Dynamic.spec
  Monitor.spec
  Input.spec
  Mode.spec
  Linking.spec
  Opacity.spec
