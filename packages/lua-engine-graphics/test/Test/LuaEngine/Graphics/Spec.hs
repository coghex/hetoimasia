-- | The lifecycle examples of the graphics adapter, composed. They run over an injected owner and need no
-- device, display or GLFW session; the real-device suite (@lua-engine-graphics-native-tests@) is separate.
module Test.LuaEngine.Graphics.Spec (spec) where

import qualified Test.LuaEngine.Graphics.Cancellation as Cancellation
import qualified Test.LuaEngine.Graphics.Composed as Composed
import qualified Test.LuaEngine.Graphics.Configuration as Configuration
import qualified Test.LuaEngine.Graphics.Facade as Facade
import qualified Test.LuaEngine.Graphics.Faults as Faults
import qualified Test.LuaEngine.Graphics.Integrated as Integrated
import qualified Test.LuaEngine.Graphics.Lifecycle as Lifecycle
import qualified Test.LuaEngine.Graphics.Peers as Peers
import qualified Test.LuaEngine.Graphics.Pressure as Pressure
import qualified Test.LuaEngine.Graphics.Release as Release
import qualified Test.LuaEngine.Graphics.SceneFrames as SceneFrames
import qualified Test.LuaEngine.Graphics.ScenePublication as ScenePublication
import qualified Test.LuaEngine.Graphics.Scenes as Scenes
import qualified Test.LuaEngine.Graphics.Stages as Stages
import qualified Test.LuaEngine.Graphics.Teardown as Teardown
import qualified Test.LuaEngine.Graphics.Window.Spec as Window
import Test.Hspec (Spec)

spec ∷ Spec
spec = do
  Configuration.spec
  Stages.spec
  Cancellation.spec
  Faults.spec
  Pressure.spec
  Release.spec
  Teardown.spec
  Lifecycle.spec
  Composed.spec
  Window.spec
  Scenes.spec
  SceneFrames.spec
  ScenePublication.spec
  Facade.spec
  Peers.spec
  Integrated.spec
