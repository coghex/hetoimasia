-- | Entry point for the diagnostics package's suite.
--
-- The examples live in the component specs 'Test.GPU.Vulkan.Diagnostics.Spec'
-- composes; this module declares none of its own. 'configFailOnEmpty' makes a
-- selection that matches no example a failure rather than a silent pass.
module Main (main) where

import qualified Test.GPU.Vulkan.Diagnostics.Spec as Diagnostics
import Test.Hspec.Runner (Config (configFailOnEmpty), defaultConfig, hspecWith)

main ∷ IO ()
main = hspecWith defaultConfig {configFailOnEmpty = True} Diagnostics.spec
