-- | Entry point for the image2d sample's headless suite.
--
-- The examples live in the modules below; this module declares none of its
-- own. They need no device, display or GLFW session. 'configFailOnEmpty'
-- makes a selection that matches no example a failure rather than a silent
-- pass.
--
-- @tools/vulkan/run.sh test@ is what builds and runs this suite, as part of
-- the validation group @test.vulkan-headless@.
module Main (main) where

import qualified Test.Sample.Image2d.Assets as Assets
import qualified Test.Sample.Image2d.Record as Record
import qualified Test.Sample.Image2d.Scene as Scene
import Test.Hspec.Runner (Config (configFailOnEmpty), defaultConfig, hspecWith)

main ∷ IO ()
main = hspecWith defaultConfig {configFailOnEmpty = True} (Assets.spec >> Scene.spec >> Record.spec)
