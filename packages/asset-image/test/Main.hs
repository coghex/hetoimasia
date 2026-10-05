-- | Entry point for the asset-image package's suite.
--
-- The examples live in the component specs 'Test.Asset.Image.Spec' composes;
-- this module declares none of its own.
--
-- 'configFailOnEmpty' makes a selection that matches no example a failure
-- rather than a silent pass.
module Main (main) where

import qualified Test.Asset.Image.Spec as AssetImage
import Test.Hspec.Runner (Config (configFailOnEmpty), defaultConfig, hspecWith)

main ∷ IO ()
main = hspecWith defaultConfig {configFailOnEmpty = True} AssetImage.spec
