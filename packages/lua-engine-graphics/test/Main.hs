-- | Entry point for the graphics adapter's lifecycle suite.
--
-- The examples live in the specs "Test.LuaEngine.Graphics.Spec" composes; this module declares none of its
-- own. They need no device, display or GLFW session: the backend runs over an injected owner.
-- 'configFailOnEmpty' makes a selection that matches no example a failure rather than a silent pass.
--
-- @tools/vulkan/run.sh test@ builds and runs this suite as part of the validation group
-- @test.vulkan-headless@.
module Main (main) where

import qualified Test.LuaEngine.Graphics.Spec as Graphics
import Test.Hspec.Runner (Config (configFailOnEmpty), defaultConfig, hspecWith)

main ∷ IO ()
main = hspecWith defaultConfig {configFailOnEmpty = True} Graphics.spec
