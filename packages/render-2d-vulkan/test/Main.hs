-- | Entry point for the 2D renderer's Vulkan recorder's headless suite.
--
-- The examples live in the modules below; this module declares none of its
-- own. They need no device, display or GLFW session: the recorder records
-- through a stand-in native layer. 'configFailOnEmpty' makes a selection that
-- matches no example a failure rather than a silent pass.
--
-- @tools/vulkan/run.sh test@ is what builds and runs this suite, as part of
-- the validation group @test.vulkan-headless@.
module Main (main) where

import qualified Test.Render.TwoD.Vulkan.Layout as Layout
import qualified Test.Render.TwoD.Vulkan.Recording as Recording
import qualified Test.Render.TwoD.Vulkan.Windows as Windows
import Test.Hspec.Runner (Config (configFailOnEmpty), defaultConfig, hspecWith)

main ∷ IO ()
main = hspecWith defaultConfig {configFailOnEmpty = True} (Layout.spec >> Recording.spec >> Windows.spec)
