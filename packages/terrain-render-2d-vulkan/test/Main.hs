-- | Entry point for the terrain-render-2d-vulkan package's device-free suite.
--
-- 'configFailOnEmpty' makes a selection that matches no example a failure rather
-- than a silent pass.
module Main (main) where

import Test.Hspec.Runner (Config (configFailOnEmpty), defaultConfig, hspecWith)
import qualified Test.Terrain.Render2D.Vulkan.Material as Material

main ∷ IO ()
main = hspecWith defaultConfig {configFailOnEmpty = True} Material.spec
