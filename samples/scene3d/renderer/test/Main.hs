-- | Entry point for the scene3d sample's headless suite.
--
-- The examples live in the modules below; this module declares none of its
-- own. They need no device, display or GLFW session. 'configFailOnEmpty'
-- makes a selection that matches no example a failure rather than a silent
-- pass.
--
-- @tools/vulkan/run.sh test@ is what builds and runs this suite, as part of
-- the validation group @test.vulkan-headless@.
module Main (main) where

import qualified Test.Sample.Scene3d.Camera as Camera
import qualified Test.Sample.Scene3d.Oracle as Oracle
import qualified Test.Sample.Scene3d.Png as Png
import qualified Test.Sample.Scene3d.Record as Record
import qualified Test.Sample.Scene3d.Scene as Scene
import Test.Hspec.Runner (Config (configFailOnEmpty), defaultConfig, hspecWith)

main ∷ IO ()
main = hspecWith defaultConfig {configFailOnEmpty = True} (Scene.spec >> Camera.spec >> Oracle.spec >> Png.spec >> Record.spec)
