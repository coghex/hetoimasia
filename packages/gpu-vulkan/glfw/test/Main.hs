-- | Entry point for the Vulkan window integration's headless suite.
--
-- The examples live in "Test.GPU.Vulkan.GLFW.Controller"; this module
-- declares none of its own. 'configFailOnEmpty' makes a selection that
-- matches no example a failure rather than a silent pass.
--
-- @tools/vulkan/run.sh test@ is what builds and runs this suite, as part of
-- the validation group @test.vulkan-headless@.
module Main (main) where

import qualified Test.GPU.Vulkan.GLFW.Controller as Controller
import Test.Hspec.Runner (Config (configFailOnEmpty), defaultConfig, hspecWith)

main ∷ IO ()
main = hspecWith defaultConfig {configFailOnEmpty = True} Controller.spec
