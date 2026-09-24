-- | Entry point for the Vulkan window integration's headless suite.
--
-- The examples live in "Test.GPU.Vulkan.GLFW.Controller"; this module
-- declares none of its own. 'configFailOnEmpty' makes a selection that
-- matches no example a failure rather than a silent pass.
--
-- @tools/vulkan-proof/run-proof.sh --headless@ is what builds and runs this
-- suite, and it hands every suite it runs its own @--headless@ mode flag, which
-- means nothing more here than it already is. It is dropped before Hspec reads
-- the arguments.
module Main (main) where

import System.Environment (getArgs, withArgs)
import qualified Test.GPU.Vulkan.GLFW.Controller as Controller
import Test.Hspec.Runner (Config (configFailOnEmpty), defaultConfig, hspecWith)

main ∷ IO ()
main = do
  arguments ← filter (/= "--headless") <$> getArgs
  withArgs arguments (hspecWith defaultConfig {configFailOnEmpty = True} Controller.spec)
