-- | Entry point for the terrain-render-2d package's suite.
--
-- 'configFailOnEmpty' makes a selection that matches no example a failure
-- rather than a silent pass.
module Main (main) where

import Test.Hspec.Runner (Config (configFailOnEmpty), defaultConfig, hspecWith)
import qualified Test.TerrainRender2D.Spec as TerrainRender2D

main ∷ IO ()
main = hspecWith defaultConfig {configFailOnEmpty = True} TerrainRender2D.spec
