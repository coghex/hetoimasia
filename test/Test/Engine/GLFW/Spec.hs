-- | The GLFW component's headless examples.
--
-- None of them initializes GLFW or opens a display. The session examples in
-- "Test.Engine.GLFW.Session" drive the production session model through the
-- private test seam; "Test.Engine.GLFW.WindowModel" runs the window model
-- examples, which use the seam's private drivers, from their own executable;
-- "Test.Engine.GLFW.Linking" checks the package's link
-- declarations against the native manifest; and "Test.Engine.GLFW.Opacity"
-- compiles external clients against the package. All are composed into this
-- group, so @--match GLFW@ selects all of them. The real native session is
-- exercised separately by the package's @glfw-native-check@ component.
module Test.Engine.GLFW.Spec (spec) where

import qualified Test.Engine.GLFW.Linking as Linking
import qualified Test.Engine.GLFW.Opacity as Opacity
import qualified Test.Engine.GLFW.Session as Session
import qualified Test.Engine.GLFW.WindowModel as WindowModel
import Test.Hspec (Spec, describe)

spec ∷ Spec
spec = describe "GLFW" $ do
  Session.spec
  WindowModel.spec
  Linking.spec
  Opacity.spec
