-- | Entry point for the triangle sample's headless suite.
--
-- The examples live in "Test.Sample.Triangle.Pipelines"; this module declares
-- none of its own. They need no device, display or GLFW session.
-- 'configFailOnEmpty' makes a selection that matches no example a failure
-- rather than a silent pass.
--
-- @tools/vulkan/run.sh test@ is what builds and runs this suite, as part of
-- the validation group @test.vulkan-headless@.
module Main (main) where

import qualified Test.Sample.Triangle.Pipelines as Pipelines
import Test.Hspec.Runner (Config (configFailOnEmpty), defaultConfig, hspecWith)

main ∷ IO ()
main = hspecWith defaultConfig {configFailOnEmpty = True} Pipelines.spec
