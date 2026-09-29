-- | Entry point for the Vulkan window integration's headless suite.
--
-- The examples live in "Test.GPU.Vulkan.GLFW.Controller"; for VK-16's loop
-- adapter and the owner's rendering, "Test.GPU.Vulkan.GLFW.Loop"; and for
-- VK-19's consumer construction and verification capture,
-- "Test.GPU.Vulkan.GLFW.Consumer". This module declares none of its own. 'configFailOnEmpty' makes a selection that
-- matches no example a failure rather than a silent pass.
--
-- @tools/vulkan/run.sh test@ is what builds and runs this suite, as part of
-- the validation group @test.vulkan-headless@.
module Main (main) where

import qualified Test.GPU.Vulkan.GLFW.Consumer as Consumer
import qualified Test.GPU.Vulkan.GLFW.Controller as Controller
import qualified Test.GPU.Vulkan.GLFW.Loop as Loop
import Test.Hspec.Runner (Config (configFailOnEmpty), defaultConfig, hspecWith)

main ∷ IO ()
main = hspecWith defaultConfig {configFailOnEmpty = True} (Controller.spec >> Loop.spec >> Consumer.spec)
